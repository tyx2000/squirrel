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
    static let columnCount = 4
    static let contentPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let cardMaxHeight: CGFloat = 150
}

struct ContentView: View {
    @EnvironmentObject private var clipboardStore: ClipboardHistoryStore
    @EnvironmentObject private var hotKeyManager: HotKeyManager
    @EnvironmentObject private var windowManager: WindowManager

    @State private var selectedTab: MainTab = .history

    var body: some View {
        VStack(spacing: 0) {
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
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
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
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(AppPalette.topBarBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .history:
            clipboardHistoryGrid(
                items: clipboardStore.items,
                emptyTitle: "No Clipboard History",
                emptySubtitle: "Copied text and images will appear here automatically."
            ) { item in
                ClipboardHistoryCard(
                    item: item,
                    imageURLProvider: { clipboardStore.imageURL(for: item) },
                    imageDataProvider: { clipboardStore.imageData(for: item) },
                    onCopy: { clipboardStore.copyToPasteboardAndPromote(item) },
                    onDelete: { clipboardStore.delete(item) }
                )
            }
        case .shortcuts:
            shortcutsView
        }
    }

    private func clipboardHistoryGrid<Card: View>(
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
                    HStack(alignment: .top, spacing: ClipboardLayout.columnSpacing) {
                        ForEach(0..<ClipboardLayout.columnCount, id: \.self) { columnIndex in
                            LazyVStack(spacing: ClipboardLayout.cardSpacing) {
                                ForEach(itemsForColumn(items, columnIndex: columnIndex)) { item in
                                    card(item)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(ClipboardLayout.contentPadding)
                }
            }
        }
    }

    private func itemsForColumn(_ items: [ClipboardItem], columnIndex: Int) -> [ClipboardItem] {
        items.enumerated().compactMap { index, item in
            index % ClipboardLayout.columnCount == columnIndex ? item : nil
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
    @State private var isHovering = false

    private var sourceApplicationName: String? {
        guard let name = item.sourceApplicationName, !name.isEmpty else { return nil }
        return name
    }

    private var canUseItem: Bool {
        item.isImage || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let sourceApplicationName {
                        Text(sourceApplicationName)
                    } else {
                        Text("")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

                Spacer(minLength: 0)

                Text(item.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(1)
            }

            Group {
                if item.isImage {
                    ClipboardImagePreview(
                        imageID: item.id,
                        imageURLProvider: imageURLProvider,
                        imageDataProvider: imageDataProvider
                    )
                } else {
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .center) {
            HStack(spacing: 8) {
                HistoryActionButton(
                    systemName: "doc.on.doc",
                    help: "Copy",
                    isEnabled: canUseItem,
                    action: onCopy
                )

                HistoryActionButton(
                    systemName: "trash",
                    help: "Delete",
                    isDestructive: true,
                    action: onDelete
                )
            }
            .padding(6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            )
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.96)
            .allowsHitTesting(isHovering)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(maxWidth: .infinity, maxHeight: ClipboardLayout.cardMaxHeight, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? AppPalette.rowHover : AppPalette.cardBackground)
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0), radius: 14, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.separator.opacity(0.75), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}

private struct ClipboardImagePreview: View {
    let imageID: UUID
    let imageURLProvider: () -> URL?
    let imageDataProvider: () -> Data?
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(AppPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 92)
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
        if let imageURL = imageURLProvider(),
           let thumbnail = ClipboardImageThumbnail.make(from: imageURL) {
            return thumbnail
        }

        if let imageData = imageDataProvider() {
            return ClipboardImageThumbnail.make(from: imageData)
        }

        return nil
    }
}

private enum ClipboardImageThumbnail {
    static func make(from url: URL) -> NSImage? {
        let options = thumbnailOptions

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: 38, height: 38))
    }

    static func make(from data: Data) -> NSImage? {
        let options = thumbnailOptions

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return NSImage(data: data)
        }

        return NSImage(cgImage: image, size: NSSize(width: 38, height: 38))
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
    let help: String
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? Color.red.opacity(0.9) : Color.primary.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(hoverBackground)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var hoverBackground: Color {
        guard isHovering && isEnabled else { return .clear }
        return isDestructive ? AppPalette.destructiveHover : AppPalette.buttonHover
    }
}
