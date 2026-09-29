//
//  FileActionList.swift
//  GitSprout
//

import AppKit
import SwiftUI

struct SectionMenuItem: Identifiable {
    var id: String
    var title: String
    var destructive = false
    var disabled = false
    var shortcut: KeyboardShortcut?
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
            let added = new.subtracting(old)
            onFocus(added.first ?? new.first)
        }
        .onChange(of: order) { _, valid in
            retarget(valid)
        }
        .selectionArrows(target: .files) { delta in
            nudge(delta)
        }
        .onKeyPress(.space) {
            guard keyboardFocus?.target == .files, allowsStage, !selection.isEmpty, !isMutating else { return .ignored }
            onToggle(Array(selection))
            return .handled
        }
    }

    @ViewBuilder
    private func menuButton(_ item: SectionMenuItem) -> some View {
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
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor ?? selection.first,
                  let start = order.firstIndex(of: anchor),
                  let end = order.firstIndex(of: file) {
            selection = Set(order[min(start, end)...max(start, end)])
        } else {
            selection = [file]
            selectionAnchor = file
        }
        keyboardFocus?.target = .files
    }

    private func nudge(_ delta: Int) {
        let files = order
        guard !files.isEmpty else { return }
        let start: Int
        if selection.count == 1, let current = selection.first, let index = files.firstIndex(of: current) {
            start = index
        } else {
            start = delta > 0 ? -1 : files.count
        }
        let next = files[min(max(0, start + delta), files.count - 1)]
        selection = [next]
        selectionAnchor = next
    }

    private func retarget(_ valid: [FileSelection]) {
        let available = Set(valid)
        guard !selection.isSubset(of: available) else { return }
        var next = Set<FileSelection>()
        for item in selection {
            if available.contains(item) {
                next.insert(item)
            } else if item.commitOID == nil {
                let flipped = FileSelection(path: item.path, staged: !item.staged)
                if available.contains(flipped) {
                    next.insert(flipped)
                }
            }
        }
        selection = next
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
                onStageLines: onStageLines
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
