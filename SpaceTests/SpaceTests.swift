//
//  SpaceTests.swift
//  SpaceTests
//
//  Created by EAdib on 2026/5/18.
//
// Purpose: Verifies clipboard history storage, bounded retention, copy promotion, pasteboard clearing, and image files.

import AppKit
import Carbon
import Foundation
import Testing
@testable import Space

@MainActor
struct SpaceTests {

    @Test func clipboardHistoryDeduplicatesAndKeepsMostRecentCopy() async throws {
        let store = ClipboardHistoryStore(storageURL: nil)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        store.addText("hello", at: firstDate)
        store.addText("world", at: secondDate)
        store.addText("hello", at: secondDate)

        #expect(store.items.map(\.text) == ["hello", "world"])
        #expect(store.items.first?.createdAt == secondDate)
    }

    @Test func clipboardHistoryKeepsOnlyMostRecentItemsWithinLimit() async throws {
        let store = ClipboardHistoryStore(storageURL: nil, maxItemCount: 2)

        store.addText("old", at: Date(timeIntervalSince1970: 0))
        store.addText("middle", at: Date(timeIntervalSince1970: 10))
        store.addText("new", at: Date(timeIntervalSince1970: 20))

        #expect(store.items.map(\.text) == ["new", "middle"])
    }

    @Test func clipboardHistoryRemovesItemsOlderThanRetentionWindow() async throws {
        let store = ClipboardHistoryStore(storageURL: nil, retentionInterval: 10)

        store.addText("old", at: Date(timeIntervalSince1970: 0))
        store.addText("new", at: Date(timeIntervalSince1970: 20))
        store.pruneHistory(now: Date(timeIntervalSince1970: 20))

        #expect(store.items.map(\.text) == ["new"])
    }

    @Test func copyingHistoryItemPromotesItToTop() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)

        store.addText("first", at: Date(timeIntervalSince1970: 100))
        store.addText("second", at: Date(timeIntervalSince1970: 200))
        let item = try #require(store.items.last)

        store.copyToPasteboardAndPromote(item)

        #expect(store.items.map(\.text) == ["first", "second"])
        #expect(pasteboard.string(forType: .string) == "first")
    }

    @Test func copyingHistoryItemDoesNotPromoteItImmediately() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)

        store.addText("first", at: Date(timeIntervalSince1970: 100))
        store.addText("second", at: Date(timeIntervalSince1970: 200))
        let item = try #require(store.items.last)

        let didCopy = store.copyToPasteboard(item)

        #expect(didCopy)
        #expect(store.items.map(\.text) == ["second", "first"])
        #expect(pasteboard.string(forType: .string) == "first")
    }

    @Test func clipboardHistoryStoresImageDataOnDiskNotInline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let imageData = try #require(Self.testImageData())

        let store = ClipboardHistoryStore(storageURL: storageURL)
        store.addImageData(imageData, at: Date())

        // Image data is always persisted to disk — never held inline in the item.
        #expect(store.items.first?.isImage == true)
        #expect(store.items.first?.imageData == nil)
        #expect(store.items.first?.imageFileName != nil)
        #expect(store.imageData(for: store.items.first!) == imageData)

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func copyingTextNamedImageKeepsImageHistoryAndItsFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let imageData = try #require(Self.testImageData())

        let store = ClipboardHistoryStore(storageURL: storageURL)
        store.addImageData(imageData, at: Date())
        let imageItem = try #require(store.items.first)
        let imageURL = try #require(store.imageURL(for: imageItem))

        // Image items carry the literal text "Image", which text dedup must not match.
        store.addText("Image", at: Date())

        #expect(store.items.filter(\.isImage).count == 1)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        let textItem = try #require(store.items.first { !$0.isImage })
        store.promoteItem(textItem)

        #expect(store.items.filter(\.isImage).count == 1)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func vacuumRefusesToSelectAWholeUserDataCategory() async throws {
        #expect(VacuumItemKind.applicationSupport.isUserData)
        #expect(VacuumItemKind.simulator.isUserData)
        #expect(VacuumItemKind.cache.isUserData == false)
    }

    @Test func clipboardHistoryRejectsImageDataWhenDiskStorageUnavailable() async throws {
        // storageURL: nil → no disk backing → image storage must fail gracefully.
        let store = ClipboardHistoryStore(storageURL: nil)
        let imageData = try #require(Self.testImageData())

        store.addImageData(imageData, at: Date())

        #expect(store.items.isEmpty)
        #expect(store.lastError == "Failed to store clipboard image to disk.")
    }

    @Test func clipboardHistoryPersistsImageDataOutsideItemMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let imageData = try #require(Self.testImageData())

        let store = ClipboardHistoryStore(storageURL: storageURL)
        store.addImageData(imageData, at: Date())
        let item = try #require(store.items.first)

        #expect(item.isImage == true)
        #expect(item.imageData == nil)
        #expect(item.imageFileName != nil)
        #expect(store.imageData(for: item) == imageData)

        let reloadedStore = ClipboardHistoryStore(storageURL: storageURL)
        let reloadedItem = try #require(reloadedStore.items.first)
        #expect(reloadedItem.imageData == nil)
        #expect(reloadedStore.imageData(for: reloadedItem) == imageData)

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func deletingPersistedImageRemovesImageFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let imageData = try #require(Self.testImageData())

        let store = ClipboardHistoryStore(storageURL: storageURL)
        store.addImageData(imageData, at: Date(timeIntervalSince1970: 100))
        let item = try #require(store.items.first)
        let fileName = try #require(item.imageFileName)
        let imageURL = directory
            .appendingPathComponent("ClipboardImages", isDirectory: true)
            .appendingPathComponent(fileName)

        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        store.delete(item)

        #expect(!FileManager.default.fileExists(atPath: imageURL.path))

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func clipboardHistoryStoresSourceApplicationName() async throws {
        let store = ClipboardHistoryStore(storageURL: nil)

        store.addText("from xcode", sourceApplicationName: "Xcode", at: Date(timeIntervalSince1970: 100))

        #expect(store.items.first?.sourceApplicationName == "Xcode")
    }

    @Test func clipboardHistoryRejectsTextLargerThanByteLimit() async throws {
        let store = ClipboardHistoryStore(storageURL: nil)
        let oversizedText = String(repeating: "😀", count: 25_001)

        store.addText(oversizedText, at: Date(timeIntervalSince1970: 100))

        #expect(store.items.isEmpty)
        #expect(store.lastError == "Clipboard text too large (max 100KB)")
    }

    @Test func clipboardHistoryRejectsStoredTextLargerThanByteLimitAfterTrimming() async throws {
        let store = ClipboardHistoryStore(storageURL: nil)
        let oversizedText = String(repeating: " ", count: 100_001) + "x"

        store.addText(oversizedText, at: Date(timeIntervalSince1970: 100))

        #expect(store.items.isEmpty)
        #expect(store.lastError == "Clipboard text too large (max 100KB)")
    }

    @Test func windowLayoutUsesTwoThirdsWidthForShortcutModes() async throws {
        let visibleFrame = CGRect(x: 10, y: 20, width: 900, height: 600)

        #expect(WindowLayoutCalculator.targetFrame(for: .leftHalf, in: visibleFrame) == CGRect(x: 10, y: 20, width: 600, height: 600))
        #expect(WindowLayoutCalculator.targetFrame(for: .rightHalf, in: visibleFrame) == CGRect(x: 310, y: 20, width: 600, height: 600))
        #expect(WindowLayoutCalculator.targetFrame(for: .centerHalf, in: visibleFrame) == CGRect(x: 160, y: 20, width: 600, height: 600))
    }

    @Test func windowLayoutFloorsFractionalTwoThirdsWidth() async throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)

        #expect(WindowLayoutCalculator.targetFrame(for: .leftHalf, in: visibleFrame).width == 666)
    }

    @Test func windowMovePreservesCurrentWindowSize() async throws {
        let visibleFrame = CGRect(x: 10, y: 20, width: 900, height: 600)
        let currentFrame = CGRect(x: 120, y: 180, width: 320, height: 240)

        #expect(WindowLayoutCalculator.targetFrame(for: .left, currentFrame: currentFrame, in: visibleFrame) == CGRect(x: 10, y: 180, width: 320, height: 240))
        #expect(WindowLayoutCalculator.targetFrame(for: .center, currentFrame: currentFrame, in: visibleFrame) == CGRect(x: 300, y: 180, width: 320, height: 240))
        #expect(WindowLayoutCalculator.targetFrame(for: .right, currentFrame: currentFrame, in: visibleFrame) == CGRect(x: 590, y: 180, width: 320, height: 240))
    }

    @Test func windowMoveClampsVerticalPositionInsideVisibleFrame() async throws {
        let visibleFrame = CGRect(x: 0, y: 50, width: 800, height: 500)
        let currentFrame = CGRect(x: 120, y: 10, width: 300, height: 200)

        #expect(WindowLayoutCalculator.targetFrame(for: .left, currentFrame: currentFrame, in: visibleFrame).minY == 50)
    }

    @Test func copyingImageItemPromotesItAndWritesPasteboardImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: storageURL)
        let firstImageData = try #require(Self.testImageData(color: .red))
        let secondImageData = try #require(Self.testImageData(color: .blue))

        store.addImageData(firstImageData, at: Date(timeIntervalSince1970: 100))
        store.addImageData(secondImageData, at: Date(timeIntervalSince1970: 200))
        let item = try #require(store.items.last)

        store.copyToPasteboardAndPromote(item)

        // Image data is always on disk — use imageData(for:) to read it back.
        #expect(store.imageData(for: store.items.first!) == firstImageData)
        #expect(pasteboard.readObjects(forClasses: [NSImage.self])?.first is NSImage)

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func captureCropRectConvertsSelectionPointsToSnapshotPixels() async throws {
        let cropRect = ScreenCaptureService.pixelCropRect(
            for: CGRect(x: 20, y: 30, width: 100, height: 50),
            snapshotPointSize: CGSize(width: 400, height: 300),
            snapshotPixelSize: CGSize(width: 800, height: 600)
        )

        #expect(cropRect == CGRect(x: 40, y: 440, width: 200, height: 100))
    }

    @Test func captureResizeHandlePrefersNearestHandleWhenHitZonesOverlap() async throws {
        let metrics = CaptureResizeHandleMetrics(
            cornerSize: CGSize(width: 4, height: 4),
            edgeThickness: 4,
            edgeLength: 28,
            hitOutset: 8
        )
        let selectionRect = CGRect(x: 0, y: 0, width: 20, height: 20)

        let handle = CaptureResizeHandleGeometry.handle(
            at: CGPoint(x: 8, y: 20),
            in: selectionRect,
            metrics: metrics
        )

        #expect(handle == .top)
    }

    @Test func captureResizeHandleKeepsCornerHandleNearCorner() async throws {
        let metrics = CaptureResizeHandleMetrics(
            cornerSize: CGSize(width: 4, height: 4),
            edgeThickness: 4,
            edgeLength: 28,
            hitOutset: 8
        )
        let selectionRect = CGRect(x: 0, y: 0, width: 20, height: 20)

        let handle = CaptureResizeHandleGeometry.handle(
            at: CGPoint(x: 1, y: 20),
            in: selectionRect,
            metrics: metrics
        )

        #expect(handle == .topLeft)
    }

    @Test func clipboardImagePixelCountUsesBackingPixels() async throws {
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 400,
            pixelsHigh: 300,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        image.addRepresentation(representation)

        #expect(ClipboardHistoryStore.imagePixelCount(for: image) == 120_000)
    }

    @Test func deletingCurrentHistoryItemClearsPasteboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)

        store.addText("current", at: Date(timeIntervalSince1970: 100))
        let item = try #require(store.items.first)
        store.setPasteboardText("current")

        store.delete(item)

        #expect(store.items.isEmpty)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func deletingNonCurrentHistoryItemKeepsPasteboard() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)

        store.addText("old", at: Date(timeIntervalSince1970: 100))
        let item = try #require(store.items.first)
        store.setPasteboardText("new")

        store.delete(item)

        #expect(store.items.isEmpty)
        #expect(pasteboard.string(forType: .string) == "new")
    }

    @Test func hotKeyLoadingIgnoresUnknownCommandsAndKeepsDefaults() async throws {
        let customClipboardShortcut = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey))
        let rawShortcuts = [
            HotKeyCommand.clipboardWindow.rawValue: customClipboardShortcut,
            "removedFutureCommand": HotKeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey))
        ]
        let data = try JSONEncoder().encode(rawShortcuts)

        let shortcuts = HotKeyManager.shortcutsByMergingDefaults(from: data)

        #expect(shortcuts[.clipboardWindow] == customClipboardShortcut)
        #expect(shortcuts[.recordWindow] == HotKeyCombo.defaultShortcuts[.recordWindow])
        #expect(shortcuts[.lockScreen] == HotKeyCombo.defaultShortcuts[.lockScreen])
        #expect(shortcuts[.moveLeft] == HotKeyCombo.defaultShortcuts[.moveLeft])
        #expect(shortcuts[.moveCenter] == HotKeyCombo.defaultShortcuts[.moveCenter])
        #expect(shortcuts[.moveRight] == HotKeyCombo.defaultShortcuts[.moveRight])
        #expect(shortcuts[.fullscreen] == HotKeyCombo.defaultShortcuts[.fullscreen])
    }

    @Test func hotKeyDefaultsCoverEveryCommandWithUniqueCarbonIDs() async throws {
        #expect(Set(HotKeyCombo.defaultShortcuts.keys) == Set(HotKeyCommand.allCases))
        #expect(Set(HotKeyCommand.allCases.map(\.carbonID)).count == HotKeyCommand.allCases.count)
        #expect(HotKeyCommand.standaloneCommands.contains(.fullscreen))
    }

    @Test func vacuumRemovesCategoryAfterAllChildrenAreCleaned() async throws {
        let child = VacuumScanItem(
            id: "/tmp/cache-a",
            title: "cache-a",
            path: "/tmp/cache-a",
            kind: .cache,
            sizeBytes: 100,
            isSelected: true,
            isExpanded: false,
            children: []
        )
        let category = VacuumScanItem(
            id: "category:Caches",
            title: "Caches",
            path: nil,
            kind: .cache,
            sizeBytes: child.sizeBytes,
            isSelected: true,
            isExpanded: true,
            children: [child]
        )

        let remaining = DiskVacuumService.removingCleanedItems(
            ids: [child.id],
            paths: [child.path!],
            from: [category]
        )

        #expect(remaining.isEmpty)
    }

    @Test func vacuumRecalculatesPartiallyCleanedCategory() async throws {
        let removedChild = VacuumScanItem(
            id: "/tmp/cache-a",
            title: "cache-a",
            path: "/tmp/cache-a",
            kind: .cache,
            sizeBytes: 100,
            isSelected: true,
            isExpanded: false,
            children: []
        )
        let remainingChild = VacuumScanItem(
            id: "/tmp/cache-b",
            title: "cache-b",
            path: "/tmp/cache-b",
            kind: .cache,
            sizeBytes: 40,
            isSelected: false,
            isExpanded: false,
            children: []
        )
        let category = VacuumScanItem(
            id: "category:Caches",
            title: "Caches",
            path: nil,
            kind: .cache,
            sizeBytes: 140,
            isSelected: false,
            isExpanded: true,
            children: [removedChild, remainingChild]
        )

        let remaining = DiskVacuumService.removingCleanedItems(
            ids: [removedChild.id],
            paths: [removedChild.path!],
            from: [category]
        )
        let updatedCategory = try #require(remaining.first)

        #expect(updatedCategory.children == [remainingChild])
        #expect(updatedCategory.sizeBytes == remainingChild.sizeBytes)
        #expect(updatedCategory.isSelected == false)
    }

    @Test func capturePixelCoordinateFlipsViewPointAndAppliesBackingScale() async throws {
        let pointSize = CGSize(width: 100, height: 50)
        let pixelSize = CGSize(width: 200, height: 100)

        // Bottom-left in view coordinates is the last pixel row of the image.
        let bottomLeft = try #require(CaptureColorSampler.pixelCoordinate(
            forViewPoint: CGPoint(x: 0, y: 0),
            snapshotPointSize: pointSize,
            snapshotPixelSize: pixelSize
        ))
        #expect(bottomLeft.x == 0)
        #expect(bottomLeft.y == 99)

        let topRight = try #require(CaptureColorSampler.pixelCoordinate(
            forViewPoint: CGPoint(x: 99.5, y: 49.5),
            snapshotPointSize: pointSize,
            snapshotPixelSize: pixelSize
        ))
        #expect(topRight.x == 199)
        #expect(topRight.y == 1)

        #expect(CaptureColorSampler.pixelCoordinate(
            forViewPoint: CGPoint(x: -1, y: 10),
            snapshotPointSize: pointSize,
            snapshotPixelSize: pixelSize
        ) == nil)
        // The top edge itself is in bounds and samples the first pixel row.
        let topEdge = try #require(CaptureColorSampler.pixelCoordinate(
            forViewPoint: CGPoint(x: 10, y: 50),
            snapshotPointSize: pointSize,
            snapshotPixelSize: pixelSize
        ))
        #expect(topEdge.y == 0)

        #expect(CaptureColorSampler.pixelCoordinate(
            forViewPoint: CGPoint(x: 10, y: 50.5),
            snapshotPointSize: pointSize,
            snapshotPixelSize: pixelSize
        ) == nil)
    }

    @Test func captureColorSamplerReadsThePixelUnderThePoint() async throws {
        // Top half red, bottom half blue, at 2x backing scale.
        let image = try #require(Self.twoToneImage(
            top: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            bottom: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            pixelSize: CGSize(width: 4, height: 4)
        ))
        let pointSize = CGSize(width: 2, height: 2)

        let nearTop = try #require(CaptureColorSampler.color(
            in: image,
            atViewPoint: CGPoint(x: 1, y: 1.5),
            snapshotPointSize: pointSize
        ))
        #expect(nearTop == CaptureSampledColor(red: 255, green: 0, blue: 0))
        #expect(nearTop.text(in: .hex) == "#FF0000")
        #expect(nearTop.text(in: .rgb) == "rgb(255, 0, 0)")

        let nearBottom = try #require(CaptureColorSampler.color(
            in: image,
            atViewPoint: CGPoint(x: 1, y: 0.5),
            snapshotPointSize: pointSize
        ))
        #expect(nearBottom == CaptureSampledColor(red: 0, green: 0, blue: 255))
    }

    private static func twoToneImage(top: NSColor, bottom: NSColor, pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // CGContext draws bottom-up, so the second fill lands in the image's top rows.
        context.setFillColor(bottom.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(top.cgColor)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return context.makeImage()
    }

    private static func testImageData(color: NSColor = .red) -> Data? {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

}
