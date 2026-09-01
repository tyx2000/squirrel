//
//  ContentView.swift
//  Space
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

private enum AppTypography {
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let secondary = Font.system(size: 12)
    static let secondarySemibold = Font.system(size: 12, weight: .semibold)
    static let title = Font.system(size: 17, weight: .medium)
    static let metric = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let icon = Font.system(size: 13, weight: .semibold)
}

private enum MainTab: String, CaseIterable, Identifiable {
    case history
    case vacuum
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "Clipboard"
        case .vacuum: "Vacuum"
        case .shortcuts: "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .history: "doc.on.clipboard"
        case .vacuum: "gauge.with.dots.needle.bottom.100percent"
        case .shortcuts: "keyboard"
        }
    }
}

private enum WindowControl {
    case close
    case minimize
}

private enum ClipboardLayout {
    static let contentPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let rowMaxHeight: CGFloat = 300
    static let rowActionWidth: CGFloat = 82
    static let resortAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88)
}

struct ContentView: View {
    @EnvironmentObject private var clipboardStore: ClipboardHistoryStore
    @EnvironmentObject private var hotKeyManager: HotKeyManager
    @EnvironmentObject private var windowManager: WindowManager
    @EnvironmentObject private var screenCaptureService: ScreenCaptureService
    @EnvironmentObject private var screenRecordingService: ScreenRecordingService
    @EnvironmentObject private var diskVacuumService: DiskVacuumService
    @EnvironmentObject private var loginItemService: LoginItemService

    @State private var selectedTab: MainTab = .history
    @State private var selectedItemID: UUID?
    @State private var isQuitButtonHovering = false
    @State private var hoveredWindowControl: WindowControl?
    @Namespace private var cardSortNamespace

    var body: some View {
        VStack(spacing: 0) {
            if let error = clipboardStore.lastError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(AppTypography.secondary)
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
        .font(AppTypography.body)
        .onReceive(NotificationCenter.default.publisher(for: .showClipboardHistory)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = .history
            }
            selectedItemID = clipboardStore.items.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyNavigation)) { notification in
            guard selectedTab == .history,
                  let command = notification.object as? HistoryNavigationCommand else {
                return
            }
            handle(command)
        }
        .onAppear {
            selectedItemID = clipboardStore.items.first?.id
        }
        .onChange(of: clipboardStore.items.map(\.id)) { _, ids in
            // A deleted or pruned selection falls back to the newest entry.
            if let selectedItemID, ids.contains(selectedItemID) { return }
            selectedItemID = ids.first
        }
    }

    private var tabBar: some View {
        ZStack {
            windowControls

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
                                .font(AppTypography.bodyMedium)
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
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer(minLength: 0)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(AppTypography.icon)
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
            .padding(.trailing, 18)
        }
        .frame(height: 56)
        .background(AppPalette.topBarBackground)
    }

    private var windowControls: some View {
        HStack(spacing: 12) {
            WindowControlButton(
                control: .close,
                isHovering: hoveredWindowControl == .close,
                action: closeWindow
            )
            .onHover { hovering in
                hoveredWindowControl = hovering ? .close : nil
            }

            WindowControlButton(
                control: .minimize,
                isHovering: hoveredWindowControl == .minimize,
                action: minimizeWindow
            )
            .onHover { hovering in
                hoveredWindowControl = hovering ? .minimize : nil
            }
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handle(_ command: HistoryNavigationCommand) {
        let items = clipboardStore.items
        guard !items.isEmpty else { return }

        switch command {
        case .previous:
            moveSelection(by: -1, in: items)
        case .next:
            moveSelection(by: 1, in: items)
        case .copy:
            copySelectedItem(in: items)
        }
    }

    private func moveSelection(by offset: Int, in items: [ClipboardItem]) {
        let currentIndex = selectedItemID.flatMap { id in
            items.firstIndex { $0.id == id }
        }

        guard let currentIndex else {
            selectedItemID = items.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedItemID = items[nextIndex].id
    }

    private func copySelectedItem(in items: [ClipboardItem]) {
        guard let selectedItemID,
              let item = items.first(where: { $0.id == selectedItemID }),
              clipboardStore.copyToPasteboard(item) else {
            return
        }

        // Promotion moves the item to the top; selection follows it by id.
        withAnimation(ClipboardLayout.resortAnimation) {
            clipboardStore.promoteItem(item)
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }

    private func minimizeWindow() {
        NSApp.keyWindow?.miniaturize(nil)
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
                    isSelected: item.id == selectedItemID,
                    imageURLProvider: { clipboardStore.imageURL(for: item) },
                    imageDataProvider: { clipboardStore.imageData(for: item) },
                    onCopy: {
                        selectedItemID = item.id
                        guard clipboardStore.copyToPasteboard(item) else { return }
                        clipboardStore.promoteItem(item)
                    },
                    onDelete: {
                        withAnimation(ClipboardLayout.resortAnimation) {
                            clipboardStore.delete(item)
                        }
                    }
                )
                .onTapGesture {
                    selectedItemID = item.id
                }
            }
        case .vacuum:
            VacuumView()
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: ClipboardLayout.rowSpacing) {
                            ForEach(items) { item in
                                card(item)
                                    .id(item.id)
                                    .matchedGeometryEffect(id: item.id, in: cardSortNamespace)
                                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                            }
                        }
                        .padding(ClipboardLayout.contentPadding)
                        .animation(ClipboardLayout.resortAnimation, value: items.map(\.id))
                    }
                    .onChange(of: selectedItemID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var shortcutsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(HotKeyCommand.standaloneCommands) { command in
                    ShortcutRecorderView(
                        title: command.title,
                        shortcut: Binding(
                            get: { hotKeyManager.shortcut(for: command) },
                            set: { hotKeyManager.updateShortcut($0, for: command) }
                        )
                    )
                    .padding(.vertical, 1)
                }

                ShortcutRecorderGroupView(
                    title: "Move Window",
                    commands: HotKeyCommand.moveCommands,
                    shortcut: { command in
                        Binding(
                            get: { hotKeyManager.shortcut(for: command) },
                            set: { hotKeyManager.updateShortcut($0, for: command) }
                        )
                    }
                )
                .padding(.vertical, 1)

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

                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { loginItemService.isEnabled },
                        set: { loginItemService.setEnabled($0) }
                    )) {
                        Label("Open Space at Login", systemImage: "power")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer(minLength: 12)
                    Button("Check") {
                        loginItemService.refresh()
                    }
                }

                if let loginMessage = loginItemService.lastMessage {
                    HStack(spacing: 10) {
                        Label(loginMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 12)
                        Button("Dismiss") {
                            loginItemService.clearMessage()
                        }
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
                            .font(AppTypography.secondary)
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
                        .font(AppTypography.secondary)
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
                .font(AppTypography.title)
            Text(subtitle)
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct ShortcutRecorderGroupView: View {
    let title: String
    let commands: [HotKeyCommand]
    let shortcut: (HotKeyCommand) -> Binding<HotKeyCombo>

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            ForEach(commands) { command in
                CompactShortcutRecorderView(
                    title: command.title,
                    shortcut: shortcut(command)
                )
            }
        }
    }
}

private struct VacuumView: View {
    @EnvironmentObject private var diskVacuumService: DiskVacuumService
    @State private var isConfirmingClean = false

    private var userDataWarning: String {
        let titles = diskVacuumService.selectedUserDataTitles
        let listed = titles.prefix(3).joined(separator: ", ")
        let remainder = titles.count - min(titles.count, 3)
        let suffix = remainder > 0 ? " (+\(remainder) more)" : ""
        return "\(titles.count) selected item(s) hold app or user data, not caches: \(listed)\(suffix). They will be moved to Trash."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    VacuumMetricView(
                        title: "Reclaimable",
                        value: DiskVacuumService.formatBytes(diskVacuumService.totalScannedBytes)
                    )
                    VacuumMetricView(
                        title: "Selected",
                        value: DiskVacuumService.formatBytes(diskVacuumService.selectedBytes)
                    )

                    Spacer(minLength: 12)

                    Button {
                        diskVacuumService.scan()
                    } label: {
                        Label(diskVacuumService.isScanning ? "Scanning" : "Scan", systemImage: "magnifyingglass")
                    }
                    .disabled(diskVacuumService.isScanning || diskVacuumService.isCleaning)

                    if diskVacuumService.isScanning {
                        Button {
                            diskVacuumService.cancelScan()
                        } label: {
                            Label("Stop", systemImage: "xmark")
                        }
                    }

                    Button {
                        if diskVacuumService.selectedUserDataTitles.isEmpty {
                            diskVacuumService.cleanSelected()
                        } else {
                            isConfirmingClean = true
                        }
                    } label: {
                        Label("Clean", systemImage: "trash")
                    }
                    .disabled(diskVacuumService.selectedBytes == 0 || diskVacuumService.isScanning || diskVacuumService.isCleaning)
                    .alert("Move selected items to Trash?", isPresented: $isConfirmingClean) {
                        Button("Cancel", role: .cancel) {}
                        Button("Move to Trash", role: .destructive) {
                            diskVacuumService.cleanSelected()
                        }
                    } message: {
                        Text(userDataWarning)
                    }
                }

                if let currentPath = diskVacuumService.currentPath {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(currentPath)
                            .font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let message = diskVacuumService.lastMessage {
                    HStack(spacing: 10) {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(AppPalette.secondaryText)
                        Spacer()
                        Button("Dismiss") {
                            diskVacuumService.clearMessage()
                        }
                    }
                    .font(AppTypography.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AppPalette.topBarBackground)

            Rectangle()
                .fill(AppPalette.separator)
                .frame(height: 1)

            if diskVacuumService.items.isEmpty, !diskVacuumService.isScanning {
                emptyVacuumState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(diskVacuumService.items) { item in
                            VacuumItemRow(item: item, level: 0)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var emptyVacuumState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(AppPalette.secondaryText)
            Text("No Scan Results")
                .font(AppTypography.title)
            Text("Run a scan to list cleanup candidates.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VacuumMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppTypography.secondary)
                .foregroundStyle(AppPalette.secondaryText)
            Text(value)
                .font(AppTypography.metric.monospacedDigit())
                .lineLimit(1)
        }
        .frame(minWidth: 104, alignment: .leading)
    }
}

private struct VacuumItemRow: View {
    @EnvironmentObject private var diskVacuumService: DiskVacuumService

    let item: VacuumScanItem
    let level: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if item.hasChildren {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            diskVacuumService.setExpanded(!item.isExpanded, for: item.id)
                        }
                    } label: {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppTypography.icon)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 28, height: 28)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(item.hasChildren ? AppTypography.bodySemibold : AppTypography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let path = item.path {
                        Text(path)
                            .font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(item.kind.rawValue)
                            .font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                }

                Spacer(minLength: 12)

                Text(DiskVacuumService.formatBytes(item.sizeBytes))
                    .font(AppTypography.body.monospacedDigit())
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 84, alignment: .trailing)

                if item.hasChildren, item.kind.isUserData, !item.isSelected {
                    Image(systemName: "exclamationmark.triangle")
                        .font(AppTypography.icon)
                        .foregroundStyle(.orange)
                        .help("Holds app or user data — select entries individually.")
                } else {
                    Toggle("", isOn: Binding(
                        get: { item.isSelected },
                        set: { diskVacuumService.setSelected($0, for: item.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
            }
            .padding(.leading, CGFloat(level) * 28)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(level == 0 ? AppPalette.cardBackground : Color.clear)
            )

            if item.isExpanded {
                VStack(spacing: 4) {
                    ForEach(item.children) { child in
                        VacuumItemRow(item: child, level: level + 1)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ClipboardHistoryCard: View {
    let item: ClipboardItem
    let isSelected: Bool
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
                    .font(AppTypography.secondarySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(timestamp)
                    .font(AppTypography.secondary)
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
                            .font(AppTypography.body)
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
                .fill(isSelected ? AppPalette.selectedTabBackground : AppPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : AppPalette.separator.opacity(0.75),
                    lineWidth: isSelected ? 2 : 1
                )
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
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
        .task(id: imageID) {
            await loadThumbnail()
        }
        .onDisappear {
            image = nil
        }
    }

    // Full-size screenshots reach 16MP, so decode a display-sized thumbnail off the
    // main thread instead of blocking the scroll on a full decode.
    private func loadThumbnail() async {
        let imageURL = imageURLProvider()
        let imageData = imageURL == nil ? imageDataProvider() : nil
        guard imageURL != nil || imageData != nil else {
            image = nil
            return
        }

        let thumbnail = await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(url: imageURL, data: imageData)
        }.value

        guard !Task.isCancelled else { return }
        image = thumbnail
    }

    private static let thumbnailMaxPixelSize = 1800

    private static func downsampledImage(url: URL?, data: Data?) -> NSImage? {
        autoreleasepool {
            let source: CGImageSource?
            if let url {
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            } else if let data {
                source = CGImageSourceCreateWithData(data as CFData, nil)
            } else {
                source = nil
            }

            guard let source else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
            ]

            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            return NSImage(
                cgImage: thumbnail,
                size: NSSize(width: thumbnail.width, height: thumbnail.height)
            )
        }
    }
}

private struct WindowControlButton: View {
    let control: WindowControl
    let isHovering: Bool
    let action: () -> Void

    private var color: Color {
        switch control {
        case .close:
            Color(red: 1.0, green: 0.376, blue: 0.376)
        case .minimize:
            Color(red: 1.0, green: 0.741, blue: 0.157)
        }
    }

    private var iconName: String {
        switch control {
        case .close:
            "xmark"
        case .minimize:
            "minus"
        }
    }

    private var accessibilityLabel: String {
        switch control {
        case .close:
            "Close"
        case .minimize:
            "Minimize"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )

                Image(systemName: iconName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.46))
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
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
                .font(AppTypography.icon)
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
