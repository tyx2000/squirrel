// Purpose: Monitors the pasteboard, stores bounded clipboard history, and manages image persistence.

import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import os.log

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var lastError: String?

    private let pasteboard: NSPasteboard
    private let storageURL: URL?
    private let imageDirectoryURL: URL?
    private let maxItemCount: Int
    private let retentionInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private static let maxTextByteCount = 100_000
    private static let maxImageDataByteCount = 50_000_000
    static let maxImagePixelCount = 16_000_000

    init(
        pasteboard: NSPasteboard = .general,
        storageURL: URL? = ClipboardHistoryStore.defaultStorageURL,
        maxItemCount: Int = 50,
        retentionInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.pasteboard = pasteboard
        self.storageURL = storageURL
        self.imageDirectoryURL = storageURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ClipboardImages", isDirectory: true)
        self.maxItemCount = max(1, maxItemCount)
        self.retentionInterval = max(0, retentionInterval)
        self.lastChangeCount = pasteboard.changeCount
        load()
        pruneHistory()
    }

    deinit {
        timer?.invalidate()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in
                store.pollPasteboard()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func clearError() {
        lastError = nil
    }

    func pollPasteboard(now: Date = Date()) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.pollPasteboard(now: now)
            }
            return
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }

        let sourceApplicationName = currentSourceApplicationName()
        if let imageData = imageDataFromPasteboard() {
            addImageData(imageData, sourceApplicationName: sourceApplicationName, at: now)
            lastChangeCount = changeCount
        } else if let text = pasteboard.string(forType: .string) {
            addText(text, sourceApplicationName: sourceApplicationName, at: now)
            lastChangeCount = changeCount
        } else {
            pruneHistory(now: now)
            lastChangeCount = changeCount
        }
    }

    func addText(_ text: String, sourceApplicationName: String? = nil, at date: Date = Date()) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        // History preserves exact clipboard text, so enforce the byte limit on the stored payload,
        // including whitespace and multi-byte characters.
        guard text.utf8.count <= Self.maxTextByteCount else {
            lastError = "Clipboard text too large (max 100KB)"
            return
        }

        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text, sourceApplicationName: sourceApplicationName, createdAt: date), at: 0)
        pruneHistory(now: date)
        save()
    }

    @discardableResult
    func addImageData(_ imageData: Data, sourceApplicationName: String? = nil, at date: Date = Date()) -> Bool {
        guard !imageData.isEmpty else { return false }
        guard imageData.count <= Self.maxImageDataByteCount else {
            lastError = "Image too large (max 50MB)"
            return false
        }

        guard let pixelCount = Self.imagePixelCount(forImageData: imageData) else {
            lastError = "Could not read image dimensions."
            return false
        }
        guard pixelCount <= Self.maxImagePixelCount else {
            lastError = "Image too large (max 16MP)"
            return false
        }

        let id = UUID()

        // Always persist to disk — never hold large image Data inline in the items array.
        // Retry once on failure for transient I/O issues.
        var fileName = storeImageData(imageData, id: id)
        if fileName == nil {
            fileName = storeImageData(imageData, id: id)
        }

        guard let fileName else {
            lastError = "Failed to store clipboard image to disk."
            return false
        }

        // Compute fingerprint once and pass it through so removeImageItemsMatching
        // doesn't re-hash the same Data.
        let fingerprint = Self.imageFingerprint(for: imageData)

        // Only dedup after the disk write succeeds — otherwise we'd delete
        // existing items and then fail to add the replacement, losing data.
        removeImageItemsMatching(imageData, knownFingerprint: fingerprint)

        items.insert(
            ClipboardItem(
                id: id,
                text: "Image",
                imageData: nil,
                imageFileName: fileName,
                imageFingerprint: fingerprint,
                sourceApplicationName: sourceApplicationName,
                createdAt: date
            ),
            at: 0
        )
        pruneHistory(now: date)
        save()
        return true
    }

    func delete(_ item: ClipboardItem) {
        clearPasteboardIfCurrentItem(item)
        items.removeAll { $0.id == item.id }
        deleteImageFile(for: item)
        save()
    }

    func imageData(for item: ClipboardItem) -> Data? {
        if let imageData = item.imageData {
            return imageData
        }

        guard let imageFileName = item.imageFileName,
              let imageDirectoryURL else {
            return nil
        }

        return try? Data(contentsOf: imageDirectoryURL.appendingPathComponent(imageFileName))
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let imageFileName = item.imageFileName,
              let imageDirectoryURL else {
            return nil
        }

        return imageDirectoryURL.appendingPathComponent(imageFileName)
    }

    @discardableResult
    func copyToPasteboard(_ item: ClipboardItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        let itemToCopy = items[index]

        if itemToCopy.isImage {
            if let imageData = imageData(for: itemToCopy) {
                setPasteboardImageData(imageData)
                return true
            }
            return false
        }

        let normalized = itemToCopy.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        setPasteboardText(itemToCopy.text)
        return true
    }

    func copyToPasteboardAndPromote(_ item: ClipboardItem) {
        guard copyToPasteboard(item) else { return }
        promoteItem(item)
    }

    func promoteItem(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var promotedItem = items.remove(at: index)
        let now = Date()

        if promotedItem.isImage {
            promotedItem.updatedAt = now
            if let promotedImageData = imageData(for: promotedItem) {
                removeImageItemsMatching(promotedImageData)
            }
            items.insert(promotedItem, at: 0)
            save()
            return
        }

        let normalized = promotedItem.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            save()
            return
        }

        promotedItem.createdAt = now
        promotedItem.updatedAt = now
        items.removeAll { $0.text == promotedItem.text }
        items.insert(promotedItem, at: 0)
        save()
    }

    func setPasteboardText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func setPasteboardImageData(_ imageData: Data) {
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: Self.pasteboardType(forImageData: imageData))
        lastChangeCount = pasteboard.changeCount
    }

    func pruneHistory(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        var retainedItems = items.filter { $0.createdAt >= cutoff }
        if retainedItems.count > maxItemCount {
            retainedItems = Array(retainedItems.prefix(maxItemCount))
        }

        guard retainedItems.map(\.id) != items.map(\.id) else { return }

        let retainedIDs = Set(retainedItems.map(\.id))
        let removedItems = items.filter { !retainedIDs.contains($0.id) }
        items = retainedItems
        deleteImageFiles(for: removedItems)
        save()
    }

    private func load() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
            migrateLegacyImageDataToFilesIfNeeded()
        } catch {
            items = []
        }
    }

    private func save() {
        guard let storageURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: storageURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Failed to save clipboard history: \(error.localizedDescription)"
            os_log("Failed to save clipboard history: %{public}@", log: .default, type: .error, error.localizedDescription)
        }
    }

    private nonisolated static var defaultStorageURL: URL? {
        guard let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            return nil
        }

        let directory = supportDirectory.appendingPathComponent("Space", isDirectory: true)
        migrateLegacyStorage(
            from: supportDirectory.appendingPathComponent("Squirrel", isDirectory: true),
            to: directory
        )
        return directory.appendingPathComponent("clipboard-history.json")
    }

    // The app was called Squirrel before it was renamed; carry that history over once.
    private nonisolated static func migrateLegacyStorage(from legacyDirectory: URL, to directory: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDirectory.path),
              !fileManager.fileExists(atPath: directory.path) else {
            return
        }

        try? fileManager.moveItem(at: legacyDirectory, to: directory)
    }

    private func storeImageData(_ imageData: Data, id: UUID) -> String? {
        guard let imageDirectoryURL else { return nil }

        do {
            try FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
            let fileName = "\(id.uuidString).image"
            try imageData.write(to: imageDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            lastError = "Failed to store clipboard image: \(error.localizedDescription)"
            os_log("Failed to store clipboard image: %{public}@", log: .default, type: .error, error.localizedDescription)
            return nil
        }
    }

    private func removeImageItemsMatching(_ imageData: Data, knownFingerprint: String? = nil) {
        let fingerprint = knownFingerprint ?? Self.imageFingerprint(for: imageData)
        let duplicates = items.filter { item in
            guard item.isImage else { return false }
            if item.imageFingerprint == fingerprint {
                return true
            }
            guard item.imageFingerprint == nil else { return false }
            return self.imageData(for: item) == imageData
        }
        guard !duplicates.isEmpty else { return }

        let duplicateIDs = Set(duplicates.map(\.id))
        items.removeAll { duplicateIDs.contains($0.id) }
        deleteImageFiles(for: duplicates)
    }

    private func migrateLegacyImageDataToFilesIfNeeded() {
        guard imageDirectoryURL != nil else { return }

        var didMigrate = false
        for index in items.indices {
            if let imageData = items[index].imageData {
                if items[index].imageFingerprint == nil {
                    items[index].imageFingerprint = Self.imageFingerprint(for: imageData)
                    didMigrate = true
                }

                if items[index].imageFileName == nil,
                   let fileName = storeImageData(imageData, id: items[index].id) {
                    items[index].imageData = nil
                    items[index].imageFileName = fileName
                    didMigrate = true
                }
            } else if items[index].isImage,
                      items[index].imageFingerprint == nil,
                      let imageData = imageData(for: items[index]) {
                items[index].imageFingerprint = Self.imageFingerprint(for: imageData)
                didMigrate = true
            }
        }

        if didMigrate {
            save()
        }
    }

    private func deleteImageFiles(for items: [ClipboardItem]) {
        for item in items {
            deleteImageFile(for: item)
        }
    }

    private func deleteImageFile(for item: ClipboardItem) {
        guard let imageDirectoryURL,
              let imageFileName = item.imageFileName else {
            return
        }

        try? FileManager.default.removeItem(at: imageDirectoryURL.appendingPathComponent(imageFileName))
    }

    private func imageDataFromPasteboard() -> Data? {
        // Try PNG and TIFF representations first — addImageData validates pixel limits.
        if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
            return pngData
        }

        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
            return tiffData
        }

        // Fallback: read NSImage from pasteboard and convert to TIFF.
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
            return nil
        }

        guard Self.imagePixelCount(for: image) <= Self.maxImagePixelCount else {
            lastError = "Image too large (max 16MP)"
            return nil
        }

        return autoreleasepool {
            image.tiffRepresentation
        }
    }

    static func imagePixelCount(for image: NSImage) -> Int {
        let representationPixelCount = image.representations
            .map { max($0.pixelsWide, 1) * max($0.pixelsHigh, 1) }
            .max()

        if let representationPixelCount {
            return representationPixelCount
        }

        return max(Int(image.size.width), 1) * max(Int(image.size.height), 1)
    }

    private static func imagePixelCount(forImageData imageData: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) as? [CFString: Any] else {
            return nil
        }

        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        return max(width, 1) * max(height, 1)
    }

    private static func imageFingerprint(for imageData: Data) -> String {
        SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func pasteboardType(forImageData imageData: Data) -> NSPasteboard.PasteboardType {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if imageData.prefix(pngSignature.count).elementsEqual(pngSignature) {
            return .png
        }

        return .tiff
    }

    private func currentSourceApplicationName() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return application.localizedName
    }

    private func clearPasteboardIfCurrentItem(_ item: ClipboardItem) {
        if itemMatchesPasteboard(item) {
            pasteboard.clearContents()
            lastChangeCount = pasteboard.changeCount
        }
    }

    private func itemMatchesPasteboard(_ item: ClipboardItem) -> Bool {
        if item.isImage, let itemImageData = imageData(for: item) {
            return imageDataFromPasteboard() == itemImageData
        }

        return pasteboard.string(forType: .string) == item.text
    }
}
