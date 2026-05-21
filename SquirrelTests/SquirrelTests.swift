//
//  SquirrelTests.swift
//  SquirrelTests
//
//  Created by EAdib on 2026/5/18.
//
// Purpose: Verifies clipboard history storage, bounded retention, copy promotion, pasteboard clearing, and image files.

import AppKit
import Foundation
import Testing
@testable import Squirrel

@MainActor
struct SquirrelTests {

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

    @Test func clipboardHistoryStoresImageData() async throws {
        let store = ClipboardHistoryStore(storageURL: nil)
        let imageData = try #require(Self.testImageData())

        store.addImageData(imageData, at: Date())

        #expect(store.items.first?.isImage == true)
        #expect(store.items.first?.imageData == imageData)
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

    @Test func copyingImageItemPromotesItAndWritesPasteboardImage() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let store = ClipboardHistoryStore(pasteboard: pasteboard, storageURL: nil)
        let firstImageData = try #require(Self.testImageData(color: .red))
        let secondImageData = try #require(Self.testImageData(color: .blue))

        store.addImageData(firstImageData, at: Date(timeIntervalSince1970: 100))
        store.addImageData(secondImageData, at: Date(timeIntervalSince1970: 200))
        let item = try #require(store.items.last)

        store.copyToPasteboardAndPromote(item)

        #expect(store.items.first?.imageData == firstImageData)
        #expect(pasteboard.readObjects(forClasses: [NSImage.self])?.first is NSImage)
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

    private static func testImageData(color: NSColor = .red) -> Data? {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

}
