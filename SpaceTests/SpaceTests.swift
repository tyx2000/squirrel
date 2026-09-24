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
import ImageIO
import Testing
import UniformTypeIdentifiers
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

    @Test func concealedPasteboardContentIsNotRecorded() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)

        // What a password manager puts on the pasteboard.
        let concealed = ClipboardHistoryStore.privateContentTypes[0]
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        store.pollPasteboard()
        #expect(store.items.isEmpty)

        // The next ordinary copy is still recorded.
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        store.pollPasteboard()
        #expect(store.items.map(\.text) == ["hello"])
    }

    @Test func copiedFilesAreNotRecorded() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        // An image file and a document, each copied the way Finder does it (sampled on
        // this Mac): a file link, the file's name as text, Finder's node reference, and
        // no image data at all.
        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 160, height: 120)))
        let imageFile = directory.appendingPathComponent("photo.jpg")
        try #require(Self.encoded(image, as: .jpeg)).write(to: imageFile)
        let documentFile = directory.appendingPathComponent("book.epub")
        try Data("book".utf8).write(to: documentFile)

        for file in [imageFile, documentFile] {
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            let noderef = NSPasteboard.PasteboardType("com.apple.finder.noderef")
            pasteboard.addTypes([.string, noderef], owner: nil)
            pasteboard.setString(file.lastPathComponent, forType: .string)
            pasteboard.setData(Data([0]), forType: noderef)
            store.pollPasteboard()
        }
        // Neither the file names nor the linked image file itself are recorded.
        #expect(store.items.isEmpty)

        // Ordinary text copied afterwards is still recorded.
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        store.pollPasteboard()
        #expect(store.items.map(\.text) == ["hello"])
    }

    @Test func imageCopiedWithAFileLinkIsKept() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        // What WeCom puts on the pasteboard when an image is copied (sampled on this
        // Mac): a link to its cached file, the picture itself as TIFF, and a private type.
        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 2054, height: 551)))
        let cachedFile = directory.appendingPathComponent("cached.png")
        try #require(Self.encoded(image, as: .png)).write(to: cachedFile)
        pasteboard.clearContents()
        pasteboard.writeObjects([cachedFile as NSURL])
        let weComPrivate = NSPasteboard.PasteboardType("WWKPrivatePBDataReportKey")
        pasteboard.addTypes([.tiff, weComPrivate], owner: nil)
        pasteboard.setData(try #require(Self.encoded(image, as: .tiff)), forType: .tiff)
        pasteboard.setData(Data(count: 42), forType: weComPrivate)
        store.pollPasteboard()

        #expect(store.items.count == 1)
        #expect(store.items.first?.isImage == true)
    }

    @Test func unreadableHistoryEntryKeepsTheRestAndTheOriginalFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("clipboard-history.json")

        let valid = ClipboardItem(text: "keep me", createdAt: Date())
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let original = try JSONSerialization.data(withJSONObject: [validObject, ["unexpected": true]])
        try original.write(to: storageURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: storageURL)

        #expect(store.items.map(\.text) == ["keep me"])
        #expect(store.lastError != nil)
        let backup = try #require(Self.unreadableBackup(in: directory))
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func corruptHistoryFileIsKeptBeforeAnythingOverwritesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("clipboard-history.json")
        let original = Data("not json".utf8)
        try original.write(to: storageURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: storageURL)
        #expect(store.items.isEmpty)

        // The next copy saves over the history file; the copy made at load survives.
        store.addText("new entry")
        let backup = try #require(Self.unreadableBackup(in: directory))
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func shiftAloneIsNotAcceptedAsAGlobalShortcut() async throws {
        let shiftOnly = try #require(Self.keyEvent(keyCode: kVK_ANSI_A, flags: [.shift]))
        #expect(HotKeyCombo(event: shiftOnly) == nil)

        let controlShift = try #require(Self.keyEvent(keyCode: kVK_ANSI_A, flags: [.control, .shift]))
        let combo = try #require(HotKeyCombo(event: controlShift))
        #expect(combo.modifiers == UInt32(controlKey | shiftKey))
    }

    @Test func savedShiftOnlyShortcutFallsBackToTheDefault() async throws {
        let unsafe = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        let saved = try JSONEncoder().encode([HotKeyCommand.clipboardWindow: unsafe])

        let shortcuts = HotKeyManager.shortcutsByMergingDefaults(from: saved)
        #expect(shortcuts[.clipboardWindow] == HotKeyCombo.defaultShortcuts[.clipboardWindow])
    }

    @Test func assigningATakenShortcutSwapsInsteadOfDisablingACommand() async throws {
        let defaults = HotKeyCombo.defaultShortcuts
        let captureCombo = try #require(defaults[.captureArea])

        let result = HotKeyManager.assigning(captureCombo, to: .lockScreen, in: defaults)

        #expect(result.displaced == .captureArea)
        #expect(result.shortcuts[.lockScreen] == captureCombo)
        #expect(result.shortcuts[.captureArea] == defaults[.lockScreen])
        let assigned = HotKeyCommand.allCases.compactMap { result.shortcuts[$0] }
        #expect(Set(assigned).count == HotKeyCommand.allCases.count)

        let unused = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | cmdKey))
        #expect(HotKeyManager.assigning(unused, to: .lockScreen, in: defaults).displaced == nil)
    }

    @Test func panelIsPresentedAtLaunchOnlyTheFirstTime() async throws {
        let suiteName = "SpaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppDelegate.isFirstLaunch(recordingIn: defaults))
        #expect(!AppDelegate.isFirstLaunch(recordingIn: defaults))
    }

    @Test func pinsKeepOnlyThePixelsTheirWindowCanShow() async throws {
        // A 1280 x 720 pt selection pins at 720 x 405 pt, which is 1440 x 810 px at 2x.
        let wide = PinnedImageController.maxPixelCount(
            forSelectionSize: CGSize(width: 1280, height: 720),
            backingScale: 2
        )
        #expect(wide == 1440 * 810)

        // A selection smaller than the pin limit keeps its own full resolution.
        let small = PinnedImageController.maxPixelCount(
            forSelectionSize: CGSize(width: 200, height: 100),
            backingScale: 2
        )
        #expect(small >= 400 * 200)
    }

    private static func unreadableBackup(in directory: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("clipboard-history.unreadable-") }
    }

    private static func keyEvent(keyCode: Int, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )
    }

    @Test func pdfOnThePasteboardIsNotRecorded() async throws {
        // Measured by the size it would render at, not as the single pixel a PDF reports.
        let poster = try #require(NSImage(data: Self.pdfData(side: 200 * 72)))
        #expect(ClipboardHistoryStore.imagePixelCount(for: poster) > ClipboardHistoryStore.maxImagePixelCount)

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        // A PDF is a document, not an image, at any size, and is never rasterised.
        for side: CGFloat in [200 * 72, 400] {
            pasteboard.clearContents()
            pasteboard.declareTypes([.pdf], owner: nil)
            pasteboard.setData(Self.pdfData(side: side), forType: .pdf)
            store.pollPasteboard()
        }
        #expect(store.items.isEmpty)
    }

    @Test func otherBitmapFormatsAreStillRecordedAsImages() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        // A GIF has no dedicated reader, so it goes through the bitmap fallback.
        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 120, height: 80)))
        let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
        pasteboard.declareTypes([gifType], owner: nil)
        pasteboard.setData(try #require(Self.encoded(image, as: .gif)), forType: gifType)
        store.pollPasteboard()

        #expect(store.items.count == 1)
        #expect(store.items.first?.isImage == true)
    }

    @Test func pasteboardImagesPreferCompactRepresentations() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        // What a photo app offers: an uncompressed TIFF and a JPEG of the same image.
        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 320, height: 240)))
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        pasteboard.declareTypes([.tiff, jpegType], owner: nil)
        pasteboard.setData(try #require(Self.encoded(image, as: .tiff)), forType: .tiff)
        pasteboard.setData(try #require(Self.encoded(image, as: .jpeg)), forType: jpegType)
        store.pollPasteboard()

        let stored = try #require(store.items.first.flatMap(store.imageData(for:)))
        #expect(Self.typeIdentifier(of: stored) == UTType.jpeg.identifier)
    }

    @Test func tiffEntriesAreCompactedToPNGAndStillRecognised() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 320, height: 240)))
        let tiff = try #require(Self.encoded(image, as: .tiff))
        #expect(store.addImageData(tiff))
        let originalFileName = try #require(store.items.first?.imageFileName)
        let fingerprint = store.items.first?.imageFingerprint

        var compacted: ClipboardItem?
        for _ in 0..<50 {
            if let item = store.items.first, item.imageFileName != originalFileName {
                compacted = item
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let item = try #require(compacted)
        let stored = try #require(store.imageData(for: item))
        #expect(Self.typeIdentifier(of: stored) == UTType.png.identifier)
        #expect(item.imageFingerprint == fingerprint)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ClipboardImages").appendingPathComponent(originalFileName).path
        ))

        // The same TIFF copied again is still a duplicate, not a second entry.
        #expect(store.addImageData(tiff))
        #expect(store.items.filter(\.isImage).count == 1)
    }

    @Test func copyingAJPEGEntryBackStillOffersTIFF() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(
            pasteboard: pasteboard,
            storageURL: directory.appendingPathComponent("clipboard-history.json")
        )

        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 320, height: 240)))
        #expect(store.addImageData(try #require(Self.encoded(image, as: .jpeg))))
        let item = try #require(store.items.first)
        #expect(store.copyToPasteboard(item))

        // Declared as what it is, with the system's TIFF translation for older readers.
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType(UTType.jpeg.identifier)) == true)
        #expect(pasteboard.data(forType: .tiff) != nil)
    }

    @Test func overlayWithNoMatchingScreenCancelsInsteadOfHanging() async throws {
        let image = try #require(Self.solidImage(pixelSize: CGSize(width: 64, height: 64)))
        let unknownDisplay: CGDirectDisplayID = 0xFFFF_FFF0
        var cancellations = 0
        let controller = CaptureOverlayController(
            snapshotsByDisplayID: [
                unknownDisplay: CaptureScreenSnapshot(
                    displayID: unknownDisplay,
                    image: image,
                    fullResImage: image,
                    pointSize: CGSize(width: 32, height: 32)
                )
            ],
            onComplete: { _, _, _, _, _ in },
            onCancel: { cancellations += 1 }
        )

        #expect(controller.begin() == false)
        #expect(cancellations == 1)
    }

    @Test func thumbnailsDecodeOnlyWhatThePreviewShows() async throws {
        // A tall screenshot is limited by the 230pt height: 460px at 2x.
        #expect(ClipboardThumbnail.maxPixelSize(forImagePixelSize: CGSize(width: 1000, height: 3000), backingScale: 2) == 460)
        // A wide one by the 940pt width.
        #expect(ClipboardThumbnail.maxPixelSize(forImagePixelSize: CGSize(width: 6000, height: 1000), backingScale: 2) == 1880)
        // A small image is never upscaled.
        #expect(ClipboardThumbnail.maxPixelSize(forImagePixelSize: CGSize(width: 200, height: 100), backingScale: 2) == 200)
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pdfData(side: CGFloat) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: side, height: side)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return Data()
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func encoded(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func typeIdentifier(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    @Test func annotatedCaptureKeepsTheCropsPixelSize() async throws {
        // A 1500 x 1000 pt selection cropped at 2x.
        let base = try #require(Self.solidImage(pixelSize: CGSize(width: 3000, height: 2000)))
        let selection = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let annotations = [
            CaptureAnnotation(tool: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 600, y: 400))
        ]

        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: annotations,
            selectionRect: selection
        ))

        #expect(result.width == 3000)
        #expect(result.height == 2000)
        #expect(Self.isOpaque(result))

        // The rectangle's left edge at x = 100 pt is x = 200 px; halfway up it is
        // y = 250 pt, 500 px from the bottom.
        let onStroke = try #require(Self.pixel(in: result, x: 200, yFromBottom: 500))
        #expect(onStroke.red > 200 && onStroke.green < 120 && onStroke.blue < 120)
        let inside = try #require(Self.pixel(in: result, x: 700, yFromBottom: 500))
        #expect(inside.red > 240 && inside.green > 240 && inside.blue > 240)
    }

    /// The pixel-size check above holds on every host, but the bug it guards against only
    /// reproduced where AppKit rendered at a 2x backing scale. On a 1x Mac this shows as
    /// skipped rather than passing without having exercised that case.
    @Test(.enabled("the Retina upscale regression needs a 2x screen to reproduce") {
        await MainActor.run { (NSScreen.main?.backingScaleFactor ?? 1) > 1 }
    })
    func annotatedCaptureIgnoresTheRetinaBackingScale() async throws {
        let base = try #require(Self.solidImage(pixelSize: CGSize(width: 600, height: 400)))
        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: [CaptureAnnotation(tool: .line, start: .zero, end: CGPoint(x: 300, y: 200))],
            selectionRect: CGRect(x: 0, y: 0, width: 300, height: 200)
        ))

        #expect(result.width == 600)
        #expect(result.height == 400)
    }

    @Test func unannotatedCaptureIsAnOpaqueCopyAtTheSameSize() async throws {
        let base = try #require(Self.solidImage(pixelSize: CGSize(width: 640, height: 480)))
        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: [],
            selectionRect: CGRect(x: 0, y: 0, width: 320, height: 240)
        ))

        #expect(result.width == 640)
        #expect(result.height == 480)
        #expect(Self.isOpaque(result))
    }

    @Test func captureKeepsADisplayP3ColorSpace() async throws {
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let base = try #require(Self.solidImage(pixelSize: CGSize(width: 64, height: 64), space: displayP3))

        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: [],
            selectionRect: CGRect(x: 0, y: 0, width: 32, height: 32)
        ))

        #expect(result.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func extendedRangeCaptureFallsBackToSRGBAndKeepsAnnotations() async throws {
        // An 8-bit context cannot hold an extended-range space, which is where the
        // composite used to give up and return the image without its annotations.
        let base = try #require(Self.extendedRangeImage(pixelSize: CGSize(width: 200, height: 200)))
        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: [
                CaptureAnnotation(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 80))
            ],
            selectionRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))

        #expect(result.colorSpace?.name == CGColorSpace.sRGB)
        let onStroke = try #require(Self.pixel(in: result, x: 40, yFromBottom: 100))
        #expect(onStroke.red > 200 && onStroke.green < 120 && onStroke.blue < 120)
    }

    @Test func oversizedCaptureIsScaledToFitThePixelCap() async throws {
        // 400 x 300 is 120,000 px; a 30,000 px cap halves each side.
        let base = try #require(Self.solidImage(pixelSize: CGSize(width: 400, height: 300)))
        let result = try #require(ScreenCaptureService.renderedCapture(
            from: base,
            annotations: [
                CaptureAnnotation(tool: .rectangle, start: CGPoint(x: 50, y: 30), end: CGPoint(x: 150, y: 120))
            ],
            selectionRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            maxPixelCount: 30_000
        ))

        #expect(result.width == 200)
        #expect(result.height == 150)
        #expect(result.width * result.height <= 30_000)

        // The annotation shrinks with the image: its left edge at x = 50 pt was
        // x = 100 px at full size and is x = 50 px now.
        let onStroke = try #require(Self.pixel(in: result, x: 50, yFromBottom: 75))
        #expect(onStroke.red > 200 && onStroke.green < 120 && onStroke.blue < 120)
    }

    @Test func fittedPixelSizeStaysWithinTheCapAndKeepsSmallImages() async throws {
        let fitted = ScreenCaptureService.fittedPixelSize(
            width: 6016,
            height: 3384,
            maxPixelCount: ClipboardHistoryStore.maxImagePixelCount
        )
        #expect(fitted.width * fitted.height <= ClipboardHistoryStore.maxImagePixelCount)
        #expect(abs(Double(fitted.width) / Double(fitted.height) - 6016.0 / 3384.0) < 0.01)

        let small = ScreenCaptureService.fittedPixelSize(width: 800, height: 600, maxPixelCount: 16_000_000)
        #expect(small.width == 800 && small.height == 600)

        let uncapped = ScreenCaptureService.fittedPixelSize(width: 6016, height: 3384, maxPixelCount: nil)
        #expect(uncapped.width == 6016 && uncapped.height == 3384)
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
    }

    /// Reads through the production sampler with one point per pixel, so coordinates
    /// are bottom-left like the annotations themselves.
    private static func pixel(in image: CGImage, x: Int, yFromBottom y: Int) -> CaptureSampledColor? {
        CaptureColorSampler.color(
            in: image,
            atViewPoint: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5),
            snapshotPointSize: CGSize(width: image.width, height: image.height)
        )
    }

    private static func solidImage(
        pixelSize: CGSize,
        space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
    ) -> CGImage? {
        guard let space,
              let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        return context.makeImage()
    }

    private static func extendedRangeImage(pixelSize: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 16,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
              ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        return context.makeImage()
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
