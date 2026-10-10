import AppKit
import SwiftUI

struct SectionMenuItem: Identifiable {
    var id: String
    var title: String
    var destructive = false
    var disabled = false
    var shortcut: KeyboardShortcut?
    var dividerBefore = false
    var action: () -> Void
}

struct FileSection: Identifiable {
    var id: String
    var title: String
    var files: [ListedFile]
    /// セクション全体のステージ状態。あるとき、見出しにチェックボックスを出す。
    var checked: Bool? = nil
    var trailingTitle: String?
    var trailingDisabled = false
    var onTrailing: (() -> Void)?
    var menu: [SectionMenuItem] = []
}

struct ListedFile: Identifiable, Hashable {
    var selection: FileSelection
    var displayPath: String
    var statusLabel: String
    var id: String { "\(selection.commitOID ?? "")|\(selection.staged)|\(selection.path)" }
}

/// 変更一覧と履歴で共用するファイルリスト。
/// クリックで差分を出し、この一覧にフォーカスがあるときだけスペースでステージ、上下キーで選択を動かす。
/// Shift を押した上下は、起点から範囲を伸ばして複数選択する。
/// 複数選択中のスペースはリストが先に消費するため、一覧側で受け取ってまとめて切り替える。
struct FileActionList: View {
    var sections: [FileSection]
    var isMutating: Bool
    var allowsStage = true
    var allowsDiscard: Bool
    var onFocus: (FileSelection?) -> Void
    var onToggle: ([FileSelection]) -> Void
    var onDiscard: ((FileSelection) -> Void)?
    var onOpenHistory: ((String) -> Void)?

    @Environment(\.keyboardFocus) private var keyboardFocus
    @State private var selection: Set<FileSelection> = []
    @State private var selectionAnchor: FileSelection?
    @State private var selectionLead: FileSelection?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    if section.files.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(section.files) { file in
                        row(file)
                            .tag(file.selection)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if allowsStage, let checked = section.checked {
                            StageCheckbox(isOn: checked, enabled: !section.trailingDisabled && !isMutating) {
                                section.onTrailing?()
                            }
                        }
                        Text(section.title)
                        Spacer()
                        if let trailingTitle = section.trailingTitle {
                            Button(trailingTitle) { section.onTrailing?() }
                                .disabled(section.trailingDisabled || isMutating)
                        }
                        if !section.menu.isEmpty {
                            Menu {
                                ForEach(section.menu) { item in
                                    menuButton(item)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(isMutating)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.inset)
        .keyboardTarget(.files)
        .onAppear { keyboardFocus?.claimIfIdle(.files) }
        .onChange(of: selection) { old, new in
            if let lead = selectionLead, new.contains(lead) {
                onFocus(lead)
            } else {
                let added = new.subtracting(old)
                onFocus(added.first ?? new.first)
            }
        }
        .onChange(of: order) { _, valid in
            retarget(valid)
        }
        .selectionArrows(target: .files) { delta, extending in
            nudge(delta, extending: extending)
        }
        .onKeyPress(.space) {
            guard keyboardFocus?.target == .files, allowsStage, !selection.isEmpty, !isMutating else { return .ignored }
            onToggle(Array(selection))
            return .handled
        }
        .background {
            if allowsStage {
                FileListSpaceMonitor(enabled: !isMutating && selection.count > 1) {
                    onToggle(Array(selection))
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func menuButton(_ item: SectionMenuItem) -> some View {
        if item.dividerBefore {
            Divider()
        }
        let button = Button(item.title, role: item.destructive ? .destructive : nil, action: item.action)
            .disabled(item.disabled || isMutating)
        if let shortcut = item.shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private var order: [FileSelection] {
        sections.flatMap { $0.files.map(\.selection) }
    }

    private func row(_ file: ListedFile) -> some View {
        HStack(spacing: 8) {
            if allowsStage {
                StageCheckbox(isOn: isChecked(file), enabled: !isMutating) {
                    onToggle([file.selection])
                }
            }
            HStack(spacing: 8) {
                statusIcon(file.statusLabel)
                Text(file.displayPath)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { pick(file.selection) }
        }
        .contextMenu {
            if allowsStage {
                Button(stageTitle(file.selection)) {
                    let targets = selection.contains(file.selection) ? Array(selection) : [file.selection]
                    onToggle(targets)
                }
            }
            if allowsDiscard {
                Button("Discard", role: .destructive) {
                    onDiscard?(file.selection)
                }
            }
            if let onOpenHistory {
                Button("File History") {
                    onOpenHistory(file.selection.path)
                }
            }
        }
    }

    private func isChecked(_ file: ListedFile) -> Bool {
        file.selection.commitOID == nil && file.selection.staged
    }

    private func stageTitle(_ file: FileSelection) -> String {
        file.commitOID == nil && file.staged ? String(localized: "Unstage") : String(localized: "Stage")
    }

    @ViewBuilder
    private func statusIcon(_ label: String) -> some View {
        if let symbol = statusSymbol(label) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(label))
                .frame(width: 18, alignment: .center)
                .help(statusName(label))
                .accessibilityLabel(statusName(label))
        } else if !label.isEmpty {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(statusColor(label))
                .frame(width: 18, alignment: .center)
        }
    }

    private func statusSymbol(_ label: String) -> String? {
        switch label {
        case "M": return "pencil"
        case "A": return "plus"
        case "D": return "minus"
        case "R": return "arrow.uturn.forward"
        case "C": return "doc.on.doc"
        case "T": return "arrow.triangle.2.circlepath"
        case "U": return "exclamationmark.triangle"
        case "?": return "plus"
        case "!": return "eye.slash"
        default: return nil
        }
    }

    private func statusName(_ label: String) -> String {
        switch label {
        case "M": return String(localized: "Modified")
        case "A": return String(localized: "Added")
        case "D": return String(localized: "Deleted")
        case "R": return String(localized: "Renamed")
        case "C": return String(localized: "Copied")
        case "T": return String(localized: "Type Changed")
        case "U": return String(localized: "Unmerged")
        case "?": return String(localized: "Untracked")
        case "!": return String(localized: "Ignored")
        default: return label
        }
    }

    private func statusColor(_ label: String) -> Color {
        switch label {
        case "A", "?": return .green
        case "D": return .red
        case "U": return .pink
        default: return .orange
        }
    }

    /// 一覧のクリック認識に任せると、別の一覧にフォーカスがあるとき選択が消える。ここで決める。
    private func pick(_ file: FileSelection) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if selection.contains(file) {
                selection.remove(file)
            } else {
                selection.insert(file)
            }
            selectionAnchor = file
            selectionLead = file
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor ?? selection.first,
                  let start = order.firstIndex(of: anchor),
                  let end = order.firstIndex(of: file) {
            selectionAnchor = anchor
            selectionLead = file
            selection = Set(order[min(start, end)...max(start, end)])
        } else {
            selectionAnchor = file
            selectionLead = file
            selection = [file]
        }
        keyboardFocus?.target = .files
    }

    private func nudge(_ delta: Int, extending: Bool) {
        let cursor = ListSelectionMover.move(
            SelectionCursor(selection: selection, anchor: selectionAnchor, lead: selectionLead),
            in: order,
            delta: delta,
            extending: extending
        )
        selectionAnchor = cursor.anchor
        selectionLead = cursor.lead
        selection = cursor.selection
    }

    private func retarget(_ valid: [FileSelection]) {
        let available = Set(valid)
        guard !selection.isSubset(of: available) else { return }
        var next = Set<FileSelection>()
        for item in selection {
            if let resolved = resolve(item, in: available) {
                next.insert(resolved)
            }
        }
        selectionAnchor = selectionAnchor.flatMap { resolve($0, in: available) }
        selectionLead = selectionLead.flatMap { resolve($0, in: available) }
        selection = next
    }

    private func resolve(_ item: FileSelection, in available: Set<FileSelection>) -> FileSelection? {
        if available.contains(item) { return item }
        guard item.commitOID == nil else { return nil }
        let flipped = FileSelection(path: item.path, staged: !item.staged)
        return available.contains(flipped) ? flipped : nil
    }
}

/// 複数行を選んでいるとき、リストはスペースをステージ操作まで届けない。先に受け取って選択全体を切り替える。
private struct FileListSpaceMonitor: NSViewRepresentable {
    var enabled: Bool
    var onSpace: () -> Void

    func makeNSView(context: Context) -> SpaceMonitorView {
        let view = SpaceMonitorView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: SpaceMonitorView, context: Context) {
        view.enabled = enabled
        view.onSpace = onSpace
    }
}

private final class SpaceMonitorView: NSView {
    var enabled = false
    var onSpace: () -> Void = {}
    // deinit は MainActor の外なので、監視の解除だけ分離する
    private nonisolated(unsafe) var monitor: Any?
    private static let spaceKeyCode: UInt16 = 49

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstall()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard enabled, event.window === window, !event.isARepeat, event.keyCode == Self.spaceKeyCode else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags.isEmpty else { return false }
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is NSTextView || responder is NSButton { return false }
        guard responderIsInList(responder) else { return false }
        onSpace()
        return true
    }

    /// この一覧のテーブルがキー入力を持っているときだけ受け取る。差分や隣の一覧には渡す。
    private func responderIsInList(_ responder: NSView) -> Bool {
        if let listScroll = listScrollView() {
            if responder === listScroll || responder.enclosingScrollView === listScroll {
                return true
            }
        }
        return overlapsList(responder)
    }

    private func overlapsList(_ responder: NSView) -> Bool {
        let target = convert(bounds, to: nil)
        guard target.width > 8, target.height > 8 else { return false }
        var current: NSView? = responder
        while let view = current {
            let frame = view.convert(view.bounds, to: nil)
            let widthRatio = frame.width / target.width
            if widthRatio > 0.7, widthRatio < 1.45 {
                let hit = frame.intersection(target)
                if hit.width > target.width * 0.5, hit.height > min(target.height, 40) * 0.5 {
                    return true
                }
            }
            if widthRatio >= 1.45 { break }
            current = view.superview
        }
        return false
    }

    private func listScrollView() -> NSScrollView? {
        let target = convert(bounds, to: nil)
        if let scroll = enclosingScrollView, Self.scroll(scroll, matches: target), Self.containsTable(scroll) {
            return scroll
        }
        guard let root = superview else { return nil }
        return Self.findTableScroll(in: root, overlapping: target)
    }

    private static func findTableScroll(in view: NSView, overlapping target: NSRect) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.matchesList(overlapping: target), containsTable(scroll) {
            return scroll
        }
        for subview in view.subviews {
            if let found = findTableScroll(in: subview, overlapping: target) {
                return found
            }
        }
        return nil
    }

    private static func scroll(_ scroll: NSScrollView, matches target: NSRect) -> Bool {
        scroll.matchesList(overlapping: target)
    }

    private static func containsTable(_ view: NSView) -> Bool {
        if view is NSTableView { return true }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            if document is NSTableView || containsTable(document) { return true }
        }
        return view.subviews.contains { containsTable($0) }
    }

    private func uninstall() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

private extension NSScrollView {
    func matchesList(overlapping target: NSRect) -> Bool {
        guard target.width > 8, target.height > 8 else { return false }
        let frame = convert(bounds, to: nil)
        let widthRatio = frame.width / target.width
        guard widthRatio > 0.7, widthRatio < 1.45 else { return false }
        let hit = frame.intersection(target)
        return hit.width > target.width * 0.5 && hit.height > min(target.height, 40) * 0.5
    }
}

struct StageCheckbox: NSViewRepresentable {
    var isOn: Bool
    var enabled: Bool
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: isOn, action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.press(_:)))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let fitted = nsView.fittingSize
        return CGSize(width: max(fitted.width, 14), height: min(max(fitted.height, 14), 18))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOn = isOn
        context.coordinator.action = action
        button.state = isOn ? .on : .off
        button.isEnabled = enabled
    }

    final class Coordinator: NSObject {
        var isOn: Bool
        var action: () -> Void

        init(isOn: Bool, action: @escaping () -> Void) {
            self.isOn = isOn
            self.action = action
        }

        @objc func press(_ sender: NSButton) {
            action()
            sender.state = isOn ? .on : .off
        }
    }
}

struct FileDiffPane: View {
    var title: String?
    var document: DiffDocument?
    var isLoading: Bool
    var fileStaged: Bool?
    var primaryTitle: String?
    var secondaryTitle: String?
    var actionsEnabled: Bool
    var onPrimaryFile: (() -> Void)?
    var onSecondaryFile: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onPrimaryHunk: ((DiffHunk) -> Void)?
    var onSecondaryHunk: ((DiffHunk) -> Void)?
    var onStageLines: ((String) -> Void)?
    var onFixMissingNewline: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    if let fileStaged, let onPrimaryFile {
                        StageCheckbox(isOn: fileStaged, enabled: actionsEnabled, action: onPrimaryFile)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let onOpenHistory {
                        Button("History", action: onOpenHistory)
                    }
                    if fileStaged == nil, let primaryTitle, let onPrimaryFile {
                        Button(primaryTitle, action: onPrimaryFile)
                            .disabled(!actionsEnabled)
                    }
                    if let secondaryTitle, let onSecondaryFile {
                        Button(secondaryTitle, role: .destructive, action: onSecondaryFile)
                            .disabled(!actionsEnabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            DiffView(
                document: document,
                isLoading: isLoading,
                hunkStaged: onPrimaryHunk == nil ? nil : fileStaged,
                primaryTitle: onPrimaryHunk == nil || fileStaged != nil ? nil : primaryTitle,
                secondaryTitle: onSecondaryHunk == nil ? nil : secondaryTitle,
                actionsEnabled: actionsEnabled,
                onPrimary: onPrimaryHunk,
                onSecondary: onSecondaryHunk,
                onStageLines: onStageLines,
                onFixMissingNewline: onFixMissingNewline
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
