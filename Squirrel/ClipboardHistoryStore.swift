// Purpose: Monitors the pasteboard, stores 24-hour clipboard history, and manages image persistence.

import AppKit
import Combine
import CryptoKit
import Foundation

final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let pasteboard: NSPasteboard
    private let storageURL: URL?
    private let imageDirectoryURL: URL?
    private let retentionInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastPruneAt = Date.distantPast
    private let idlePruneInterval: TimeInterval = 5 * 60

    init(
        pasteboard: NSPasteboard = .general,
        storageURL: URL? = ClipboardHistoryStore.defaultStorageURL,
        retentionInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.pasteboard = pasteboard
        self.storageURL = storageURL
        self.imageDirectoryURL = storageURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ClipboardImages", isDirectory: true)
        self.retentionInterval = retentionInterval
        self.lastChangeCount = pasteboard.changeCount
        load()
        pruneExpired()
    }

    deinit {
        timer?.invalidate()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func pollPasteboard(now: Date = Date()) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            pruneExpiredIfNeeded(now: now)
            return
        }

        lastChangeCount = changeCount
        let sourceApplicationName = currentSourceApplicationName()
        if let imageData = imageDataFromPasteboard() {
            addImageData(imageData, sourceApplicationName: sourceApplicationName, at: now)
        } else if let text = pasteboard.string(forType: .string) {
            addText(text, sourceApplicationName: sourceApplicationName, at: now)
        } else {
            pruneExpired(now: now)
        }
    }

    func addText(_ text: String, sourceApplicationName: String? = nil, at date: Date = Date()) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text, sourceApplicationName: sourceApplicationName, createdAt: date), at: 0)
        pruneExpired(now: date)
        save()
    }

    func addImageData(_ imageData: Data, sourceApplicationName: String? = nil, at date: Date = Date()) {
        guard !imageData.isEmpty else { return }

        removeImageItemsMatching(imageData)

        let id = UUID()
        let fileName = storeImageData(imageData, id: id)
        let fingerprint = Self.imageFingerprint(for: imageData)
        items.insert(
            ClipboardItem(
                id: id,
                text: "Image",
                imageData: fileName == nil ? imageData : nil,
                imageFileName: fileName,
                imageFingerprint: fingerprint,
                sourceApplicationName: sourceApplicationName,
                createdAt: date
            ),
            at: 0
        )
        pruneExpired(now: date)
        save()
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

    func copyToPasteboardAndPromote(_ item: ClipboardItem) {
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
            if let imageData = imageData(for: promotedItem) {
                setPasteboardImageData(imageData)
            }
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
        setPasteboardText(promotedItem.text)
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

    func pruneExpired(now: Date = Date()) {
        lastPruneAt = now
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let oldCount = items.count
        let expiredItems = items.filter { $0.createdAt < cutoff }
        items.removeAll { $0.createdAt < cutoff }
        if items.count != oldCount {
            deleteImageFiles(for: expiredItems)
            save()
        }
    }

    private func pruneExpiredIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastPruneAt) >= idlePruneInterval else { return }
        pruneExpired(now: now)
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
        } catch {
            assertionFailure("Failed to save clipboard history: \(error)")
        }
    }

    private static var defaultStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Squirrel", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    private func storeImageData(_ imageData: Data, id: UUID) -> String? {
        guard let imageDirectoryURL else { return nil }

        do {
            try FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
            let fileName = "\(id.uuidString).image"
            try imageData.write(to: imageDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            assertionFailure("Failed to store clipboard image: \(error)")
            return nil
        }
    }

    private func removeImageItemsMatching(_ imageData: Data) {
        let fingerprint = Self.imageFingerprint(for: imageData)
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
        if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
            return pngData
        }

        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
            return tiffData
        }

        guard let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
            return nil
        }

        return image.tiffRepresentation
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
