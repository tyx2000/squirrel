// Purpose: Scans common user cleanup locations and moves selected cleanup items to Trash.

import Foundation
import Combine

enum VacuumItemKind: String, Sendable {
    case cache = "Cache"
    case log = "Log"
    case derivedData = "Derived Data"
    case archive = "Xcode Archive"
    case simulator = "Simulator"
    case applicationSupport = "Application Support"
    case largeFile = "Large File"
}

struct VacuumScanItem: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var path: String?
    var kind: VacuumItemKind
    var sizeBytes: UInt64
    var isSelected: Bool
    var isExpanded: Bool
    var children: [VacuumScanItem]

    nonisolated var hasChildren: Bool {
        !children.isEmpty
    }
}

@MainActor
final class DiskVacuumService: ObservableObject {
    @Published private(set) var items: [VacuumScanItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var currentPath: String?
    @Published private(set) var lastMessage: String?

    var totalScannedBytes: UInt64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedBytes: UInt64 {
        Self.selectedLeafItems(in: items).reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        isCleaning = false
        currentPath = nil
        lastMessage = nil
        items = []

        Task.detached(priority: .utility) {
            let result = VacuumScanner.scan { path in
                Task { @MainActor in
                    self.currentPath = path
                }
            }

            await MainActor.run {
                self.items = result
                self.currentPath = nil
                self.isScanning = false
                self.lastMessage = result.isEmpty ? "No cleanup candidates found." : "Scan complete."
            }
        }
    }

    func clearMessage() {
        lastMessage = nil
    }

    func setExpanded(_ expanded: Bool, for id: String) {
        items = Self.updating(items, id: id) { item in
            item.isExpanded = expanded
        }
    }

    func setSelected(_ selected: Bool, for id: String) {
        items = Self.updating(items, id: id) { item in
            item.isSelected = selected
            item.children = item.children.map { child in
                var updatedChild = child
                Self.setSelectionRecursively(&updatedChild, selected: selected)
                return updatedChild
            }
        }
    }

    func cleanSelected() {
        guard !isCleaning else { return }
        let selectedItems = Self.selectedLeafItems(in: items)
        guard !selectedItems.isEmpty else {
            lastMessage = "Select at least one item to clean."
            return
        }

        isCleaning = true
        lastMessage = nil
        let selectedIDs = Set(selectedItems.map(\.id))
        let urls = Self.uniqueCleanupURLs(for: selectedItems)

        guard !urls.isEmpty else {
            isCleaning = false
            items = Self.removingEmptyCategories(from: items)
            lastMessage = "The selected items are no longer available. Run a new scan."
            return
        }

        Task.detached(priority: .utility) {
            var removedPaths = Set<String>()
            var failures: [CleanFailure] = []

            for url in urls {
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    removedPaths.insert(url.path)
                } catch {
                    failures.append(CleanFailure(path: url.path, reason: error.localizedDescription))
                }
            }

            let result = CleanResult(removedPaths: removedPaths, failures: failures)

            await MainActor.run {
                self.items = Self.removingCleanedItems(
                    ids: selectedIDs,
                    paths: result.removedPaths,
                    from: self.items
                )
                self.isCleaning = false
                if result.failures.isEmpty {
                    self.lastMessage = "Moved \(result.removedPaths.count) item(s) to Trash."
                } else {
                    self.lastMessage = Self.failureMessage(for: result)
                }
            }
        }
    }

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }

        if index == 0 {
            return "\(Int(value))\(units[index])"
        }
        if value >= 10 {
            return "\(Int(value.rounded()))\(units[index])"
        }
        return String(format: "%.1f%@", value, units[index])
    }

    private nonisolated static func selectedLeafItems(in items: [VacuumScanItem]) -> [VacuumScanItem] {
        items.flatMap { item -> [VacuumScanItem] in
            if item.hasChildren {
                return selectedLeafItems(in: item.children)
            }
            return item.isSelected && item.path != nil ? [item] : []
        }
    }

    private nonisolated static func uniqueCleanupURLs(for items: [VacuumScanItem]) -> [URL] {
        let sortedURLs = items
            .compactMap { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL } }
            .sorted { $0.path.count < $1.path.count }

        var kept: [URL] = []
        for url in sortedURLs where !isCovered(url.path, by: kept.map(\.path)) {
            kept.append(url)
        }
        return kept
    }

    nonisolated static func isCovered(_ path: String, by paths: some Sequence<String>) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private nonisolated static func updating(
        _ items: [VacuumScanItem],
        id: String,
        update: (inout VacuumScanItem) -> Void
    ) -> [VacuumScanItem] {
        items.map { item in
            var updatedItem = item
            if updatedItem.id == id {
                update(&updatedItem)
            } else {
                updatedItem.children = updating(updatedItem.children, id: id, update: update)
                if updatedItem.hasChildren {
                    updatedItem.isSelected = updatedItem.children.allSatisfy(\.isSelected)
                }
            }
            return updatedItem
        }
    }

    private nonisolated static func setSelectionRecursively(_ item: inout VacuumScanItem, selected: Bool) {
        item.isSelected = selected
        for index in item.children.indices {
            setSelectionRecursively(&item.children[index], selected: selected)
        }
    }

    nonisolated static func removingCleanedItems(
        ids: Set<String>,
        paths: Set<String>,
        from items: [VacuumScanItem]
    ) -> [VacuumScanItem] {
        items.compactMap { item in
            if ids.contains(item.id), item.path.map({ isCovered($0, by: paths) }) ?? false {
                return nil
            }

            var updatedItem = item
            let wasCategory = updatedItem.hasChildren
            updatedItem.children = removingCleanedItems(ids: ids, paths: paths, from: item.children)
            if wasCategory {
                guard !updatedItem.children.isEmpty else { return nil }
                updatedItem.sizeBytes = updatedItem.children.reduce(0) { $0 + $1.sizeBytes }
                updatedItem.isSelected = updatedItem.children.allSatisfy(\.isSelected)
            }
            return updatedItem.sizeBytes > 0 || !updatedItem.children.isEmpty ? updatedItem : nil
        }
    }

    private nonisolated static func removingEmptyCategories(from items: [VacuumScanItem]) -> [VacuumScanItem] {
        items.compactMap { item in
            var updatedItem = item
            updatedItem.children = removingEmptyCategories(from: item.children)
            if item.path == nil, updatedItem.children.isEmpty {
                return nil
            }
            return updatedItem
        }
    }

    private nonisolated static func failureMessage(for result: CleanResult) -> String {
        guard let firstFailure = result.failures.first else {
            return "Moved \(result.removedPaths.count) item(s) to Trash."
        }

        let name = URL(fileURLWithPath: firstFailure.path).lastPathComponent
        let additionalFailures = result.failures.count - 1
        let suffix = additionalFailures > 0 ? " (+\(additionalFailures) more)" : ""
        return "Moved \(result.removedPaths.count) item(s). Could not move \(name): \(firstFailure.reason)\(suffix)"
    }
}

private enum VacuumScanner {
    private nonisolated static let excludedRoots: [String] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .standardizedFileURL
            .path
    ]
    private nonisolated static let largeFileThreshold: UInt64 = 500 * 1024 * 1024
    private nonisolated static let maximumChildrenPerCategory = 80
    private nonisolated static let maximumLargeFiles = 100

    nonisolated static func scan(progress: @escaping @Sendable (String) -> Void) -> [VacuumScanItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let developer = library.appendingPathComponent("Developer", isDirectory: true)

        let targets: [ScanTarget] = [
            ScanTarget(
                title: "Caches",
                url: library.appendingPathComponent("Caches", isDirectory: true),
                kind: .cache,
                defaultSelected: true
            ),
            ScanTarget(
                title: "Logs",
                url: library.appendingPathComponent("Logs", isDirectory: true),
                kind: .log,
                defaultSelected: true
            ),
            ScanTarget(
                title: "Xcode DerivedData",
                url: developer.appendingPathComponent("Xcode/DerivedData", isDirectory: true),
                kind: .derivedData,
                defaultSelected: true
            ),
            ScanTarget(
                title: "Xcode Archives",
                url: developer.appendingPathComponent("Xcode/Archives", isDirectory: true),
                kind: .archive,
                defaultSelected: false
            ),
            ScanTarget(
                title: "Simulators",
                url: developer.appendingPathComponent("CoreSimulator/Devices", isDirectory: true),
                kind: .simulator,
                defaultSelected: false
            ),
            ScanTarget(
                title: "Application Support Large Items",
                url: library.appendingPathComponent("Application Support", isDirectory: true),
                kind: .applicationSupport,
                defaultSelected: false
            )
        ]

        var items = targets.compactMap { scanTarget($0, progress: progress) }

        if let largeFiles = scanLargeFiles(
            roots: [
                home.appendingPathComponent("Downloads", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true),
                home.appendingPathComponent("Movies", isDirectory: true)
            ],
            coveredRoots: targets.map(\.url),
            progress: progress
        ) {
            items.append(largeFiles)
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private nonisolated static func scanTarget(_ target: ScanTarget, progress: @escaping @Sendable (String) -> Void) -> VacuumScanItem? {
        guard !isExcluded(target.url) else { return nil }
        guard FileManager.default.fileExists(atPath: target.url.path) else { return nil }
        progress(target.url.path)

        let children = directChildren(of: target.url)
            .map { url -> VacuumScanItem in
                progress(url.path)
                let size = allocatedSize(of: url, progress: progress)
                return VacuumScanItem(
                    id: url.path,
                    title: displayName(for: url),
                    path: url.path,
                    kind: target.kind,
                    sizeBytes: size,
                    isSelected: target.defaultSelected,
                    isExpanded: false,
                    children: []
                )
            }
            .filter { $0.sizeBytes > 0 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(maximumChildrenPerCategory)

        let childItems = Array(children)
        guard !childItems.isEmpty else { return nil }

        return VacuumScanItem(
            id: "category:\(target.title)",
            title: target.title,
            path: nil,
            kind: target.kind,
            sizeBytes: childItems.reduce(0) { $0 + $1.sizeBytes },
            isSelected: childItems.allSatisfy(\.isSelected),
            isExpanded: false,
            children: childItems
        )
    }

    private nonisolated static func scanLargeFiles(
        roots: [URL],
        coveredRoots: [URL],
        progress: @escaping @Sendable (String) -> Void
    ) -> VacuumScanItem? {
        let coveredPaths = coveredRoots.map { $0.standardizedFileURL.path }
        let children = roots
            .filter { !isExcluded($0) && !isContained($0, in: coveredPaths) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { largeFiles(in: $0, covered: coveredPaths, progress: progress) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(maximumLargeFiles)

        let childItems = Array(children)
        guard !childItems.isEmpty else { return nil }

        return VacuumScanItem(
            id: "category:Large Files",
            title: "Large Files",
            path: nil,
            kind: .largeFile,
            sizeBytes: childItems.reduce(0) { $0 + $1.sizeBytes },
            isSelected: false,
            isExpanded: false,
            children: childItems
        )
    }

    private nonisolated static func largeFiles(
        in root: URL,
        covered: [String],
        progress: @escaping @Sendable (String) -> Void
    ) -> [VacuumScanItem] {
        var results: [VacuumScanItem] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var scannedCount = 0
        for case let url as URL in enumerator {
            scannedCount += 1
            if scannedCount % 200 == 0 {
                progress(url.path)
            }

            if isExcluded(url) || isContained(url, in: covered) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            guard size >= largeFileThreshold else { continue }

            results.append(
                VacuumScanItem(
                    id: url.path,
                    title: displayName(for: url),
                    path: url.path,
                    kind: .largeFile,
                    sizeBytes: size,
                    isSelected: false,
                    isExpanded: false,
                    children: []
                )
            )
        }

        return results
    }

    private nonisolated static func directChildren(of url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { !isExcluded($0) }
    }

    private nonisolated static func isExcluded(_ url: URL) -> Bool {
        isContained(url, in: excludedRoots)
    }

    private nonisolated static func isContained(_ url: URL, in roots: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private nonisolated static func allocatedSize(of url: URL, progress: @escaping @Sendable (String) -> Void) -> UInt64 {
        guard !isExcluded(url) else { return 0 }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }

        if values.isDirectory != true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }

        var total: UInt64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var scannedCount = 0
        for case let childURL as URL in enumerator {
            scannedCount += 1
            if scannedCount % 250 == 0 {
                progress(childURL.path)
            }

            if isExcluded(childURL) {
                enumerator.skipDescendants()
                continue
            }

            guard let childValues = try? childURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  childValues.isRegularFile == true else {
                continue
            }

            total += UInt64(childValues.totalFileAllocatedSize ?? childValues.fileSize ?? 0)
        }

        return total
    }

    private nonisolated static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

private struct ScanTarget {
    let title: String
    let url: URL
    let kind: VacuumItemKind
    let defaultSelected: Bool
}

private struct CleanResult: Sendable {
    let removedPaths: Set<String>
    let failures: [CleanFailure]
}

private struct CleanFailure: Sendable {
    let path: String
    let reason: String
}
