//
//  ContentView.swift
//  Squirrel
//
//  Created by EAdib on 2026/5/18.
//
// Purpose: Implements the main management UI for clipboard history and shortcut configuration.

import SwiftUI
import AppKit
import ImageIO

private enum AppPalette {
    static let windowBackground = Color(red: 0.965, green: 0.969, blue: 0.976)
    static let topBarBackground = Color(red: 0.992, green: 0.992, blue: 0.996)
    static let selectedTabBackground = Color(red: 0.918, green: 0.949, blue: 1.0)
    static let separator = Color(red: 0.894, green: 0.906, blue: 0.922)
    static let secondaryText = Color(red: 0.478, green: 0.506, blue: 0.549)
    static let rowHover = Color.white
    static let cardBackground = Color.white.opacity(0.82)
    static let buttonHover = Color(red: 0.929, green: 0.949, blue: 0.969)
    static let destructiveHover = Color(red: 0.992, green: 0.925, blue: 0.925)
}

private enum MainTab: String, CaseIterable, Identifiable {
    case history
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "Clipboard"
        case .shortcuts: "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .history: "doc.on.clipboard"
        case .shortcuts: "keyboard"
        }
    }
}

private enum ClipboardLayout {
    static let contentPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let rowMaxHeight: CGFloat = 300
    static let rowActionWidth: CGFloat = 82
    static let thumbnailCacheLimit = 4 * 1024 * 1024
    static let thumbnailCacheCountLimit = 24
    static let resortAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88)

    static func configureThumbnailCache() {
        let cache = ClipboardImagePreview.getThumbnailCache()
        cache.totalCostLimit = thumbnailCacheLimit
        cache.countLimit = thumbnailCacheCountLimit
    }
}

struct ContentView: View {
    @EnvironmentObject private var clipboardStore: ClipboardHistoryStore
    @EnvironmentObject private var hotKeyManager: HotKeyManager
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var screenCaptureService: ScreenCaptureService
    @EnvironmentObject private var screenRecordingService: ScreenRecordingService

    @State private var selectedTab: MainTab = .history
    @State private var isQuitButtonHovering = false
    @Namespace private var cardSortNamespace

    var body: some View {
        VStack(spacing: 0) {
            if let error = clipboardStore.lastError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { clipboardStore.clearError() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .frame(height: 40)
            }
            tabBar
            Rectangle()
                .fill(AppPalette.separator)
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppPalette.windowBackground)
        .onReceive(NotificationCenter.default.publisher(for: .showClipboardHistory)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = .history
            }
        }
        .onAppear {
            ClipboardLayout.configureThumbnailCache()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                            .frame(width: 16)
                        Text(tab.title)
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(minWidth: 116)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == tab ? AppPalette.selectedTabBackground : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
            }

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isQuitButtonHovering ? .white : .red)
                    .frame(width: 34, height: 30)
                    .background(
                        Capsule()
                            .fill(isQuitButtonHovering ? Color.red.opacity(0.92) : .clear)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Quit")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isQuitButtonHovering = hovering
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(AppPalette.topBarBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .history:
            clipboardHistoryList(
                items: clipboardStore.items,
                emptyTitle: "No Clipboard History",
                emptySubtitle: "Copied text and images will appear here automatically."
            ) { item in
                ClipboardHistoryCard(
                    item: item,
                    imageURLProvider: { clipboardStore.imageURL(for: item) },
                    imageDataProvider: { clipboardStore.imageData(for: item) },
                    onCopy: {
                        guard clipboardStore.copyToPasteboard(item) else { return }
                        MainWindowPresenter.shared.hideClipboardWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            clipboardStore.promoteItem(item)
                        }
                    },
                    onDelete: {
                        withAnimation(ClipboardLayout.resortAnimation) {
                            clipboardStore.delete(item)
                        }
                    }
                )
            }
        case .shortcuts:
            shortcutsView
        }
    }

    private func clipboardHistoryList<Card: View>(
        items: [ClipboardItem],
        emptyTitle: String,
        emptySubtitle: String,
        @ViewBuilder card: @escaping (ClipboardItem) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                emptyState(title: emptyTitle, subtitle: emptySubtitle)
            } else {
                ScrollView {
                    LazyVStack(spacing: ClipboardLayout.rowSpacing) {
                        ForEach(items) { item in
                            card(item)
                                .matchedGeometryEffect(id: item.id, in: cardSortNamespace)
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        }
                    }
                    .padding(ClipboardLayout.contentPadding)
                    .animation(ClipboardLayout.resortAnimation, value: items.map(\.id))
                }
            }
        }
    }

    private var shortcutsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(HotKeyCommand.allCases) { command in
                    ShortcutRecorderView(
                        title: command.title,
                        shortcut: Binding(
                            get: { hotKeyManager.shortcut(for: command) },
                            set: { hotKeyManager.updateShortcut($0, for: command) }
                        )
                    )
                    .padding(.vertical, 1)
                }

                Divider()
                    .overlay(AppPalette.separator)

                HStack(spacing: 10) {
                    Label(
                        windowManager.isAccessibilityTrusted ? "Accessibility Access Granted" : "Window management requires Accessibility access",
                        systemImage: windowManager.isAccessibilityTrusted ? "checkmark.circle" : "lock"
                    )
                    .foregroundStyle(windowManager.isAccessibilityTrusted ? .green : AppPalette.secondaryText)
                    Spacer(minLength: 12)
                    Button("Open Settings") {
                        windowManager.requestAccessibilityPermission()
                    }
                    Button("Check") {
                        windowManager.refreshPermissionStatus()
                    }
                }

                if let registrationError = hotKeyManager.registrationError {
                    Label(registrationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let hotKeyMessage = hotKeyManager.lastEventMessage {
                    Label(hotKeyMessage, systemImage: "keyboard.badge.eye")
                        .foregroundStyle(.orange)
                }

                if let captureMessage = screenCaptureService.lastMessage {
                    HStack(spacing: 10) {
                        Label(captureMessage, systemImage: "camera.viewfinder")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 12)
                        Button("Dismiss") {
                            screenCaptureService.clearMessage()
                        }
                    }
                }

                HStack(spacing: 10) {
                    Label(
                        screenRecordingService.isRecording ? "Recording in progress" : "Screen recording is idle",
                        systemImage: screenRecordingService.isRecording ? "record.circle" : "video"
                    )
                    .foregroundStyle(screenRecordingService.isRecording ? .red : AppPalette.secondaryText)
                    Spacer(minLength: 12)
                    if let outputURL = screenRecordingService.outputURL {
                        Text(outputURL.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                }

                if let recordingMessage = screenRecordingService.lastMessage {
                    HStack(spacing: 10) {
                        Label(recordingMessage, systemImage: "video.badge.checkmark")
                            .foregroundStyle(screenRecordingService.isRecording ? .red : AppPalette.secondaryText)
                        Spacer(minLength: 12)
                        Button("Dismiss") {
                            screenRecordingService.clearMessage()
                        }
                    }
                }

                if let message = windowManager.lastMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(AppPalette.secondaryText)
            Text(title)
                .font(.title3.weight(.medium))
            Text(subtitle)
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct ClipboardHistoryCard: View {
    let item: ClipboardItem
    let imageURLProvider: () -> URL?
    let imageDataProvider: () -> Data?
    let onCopy: () -> Void
    let onDelete: () -> Void

    private var sourceApplicationName: String? {
        guard let name = item.sourceApplicationName, !name.isEmpty else { return nil }
        return name
    }

    private var canUseItem: Bool {
        item.isImage || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text(sourceApplicationName ?? "Unknown App")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(timestamp)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                Group {
                    if item.isImage {
                        ClipboardImagePreview(
                            imageID: item.id,
                            imageURLProvider: imageURLProvider,
                            imageDataProvider: imageDataProvider
                        )
                    } else {
                        Text(item.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(11)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                HStack(spacing: 8) {
                    HistoryActionButton(
                        systemName: "doc.on.doc",
                        background: .blue,
                        isEnabled: canUseItem,
                        action: onCopy
                    )

                    HistoryActionButton(
                        systemName: "trash",
                        background: .red,
                        action: onDelete
                    )
                }
                .frame(width: ClipboardLayout.rowActionWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: ClipboardLayout.rowMaxHeight, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.separator.opacity(0.75), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var timestamp: String {
        Self.timestampFormatter.string(from: item.createdAt)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()
}

private struct ClipboardImagePreview: View {
    let imageID: UUID
    let imageURLProvider: () -> URL?
    let imageDataProvider: () -> Data?
    @State private var thumbnail: NSImage?

    private static let thumbnailCache = NSCache<NSString, NSImage>()

    static func getThumbnailCache() -> NSCache<NSString, NSImage> {
        return thumbnailCache
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(AppPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 230, alignment: .leading)
        .background(Color.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            thumbnail = makeThumbnail()
        }
        .onChange(of: imageID) { _, _ in
            thumbnail = makeThumbnail()
        }
        .onDisappear {
            thumbnail = nil
        }
    }

    private func makeThumbnail() -> NSImage? {
        let cacheKey = imageID.uuidString as NSString

        if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        var result: NSImage? = nil

        autoreleasepool {
            if let imageURL = imageURLProvider(),
               let thumbnail = ClipboardImageThumbnail.make(from: imageURL) {
                result = thumbnail
            } else if let imageData = imageDataProvider() {
                result = ClipboardImageThumbnail.make(from: imageData)
            }
        }

        if let result {
            Self.thumbnailCache.setObject(
                result,
                forKey: cacheKey,
                cost: ClipboardImageThumbnail.memoryCost(for: result)
            )
        }

        return result
    }
}

private enum ClipboardImageThumbnail {
    static func make(from url: URL) -> NSImage? {
        let options = thumbnailOptions

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func make(from data: Data) -> NSImage? {
        let options = thumbnailOptions

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func memoryCost(for image: NSImage) -> Int {
        // NSCache cost should reflect the largest single representation,
        // not the sum — the cache evicts whole entries, not individual reps.
        let representationCost = image.representations
            .map { max($0.pixelsWide, 1) * max($0.pixelsHigh, 1) * 4 }
            .max()

        if let representationCost {
            return representationCost
        }

        return max(Int(image.size.width), 1) * max(Int(image.size.height), 1) * 4
    }

    private static var thumbnailOptions: CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as CFDictionary
    }
}

private struct HistoryActionButton: View {
    let systemName: String
    let background: Color
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering && isEnabled ? .white : background)
                .frame(width: 34, height: 30, alignment: .center)
                .background(
                    Capsule()
                        .fill(isHovering && isEnabled ? background.opacity(0.92) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(systemName == "trash" ? "Delete" : "Copy")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
