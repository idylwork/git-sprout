//
//  ChangesView.swift
//  GitSprout
//

import SwiftUI

struct ChangesView: View {
    var session: WorkspaceSession

    var body: some View {
        WorktreeFileList(session: session)
    }
}

struct WorktreeFileList: View {
    var session: WorkspaceSession
    @State private var showCommitComposer = false
    @State private var showReview = false
    @State private var commitFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.statusTruncated {
                Text("Too many changes to show them all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            FileActionList(
                sections: sections,
                isMutating: session.isMutating,
                allowsDiscard: true,
                onFocus: { file in
                    Task { await session.focusWork(file) }
                },
                onToggle: { files in
                    Task { await session.toggleStage(files) }
                },
                onDiscard: { file in
                    guard let change = session.changes.first(where: { $0.path == file.path }) else { return }
                    session.pendingConfirm = file.staged ? .discardStaged(change) : .discardUnstaged(change)
                },
                onOpenHistory: { path in
                    Task { await session.openFileHistory(path) }
                }
            )
        }
        .sheet(isPresented: $showCommitComposer) {
            CommitComposer(session: session, failure: $commitFailure)
        }
        .sheet(isPresented: $showReview) {
            StagedReviewSheet(session: session)
        }
    }

    private var sections: [FileSection] {
        [
            FileSection(
                id: "staged",
                title: String(localized: "Staged"),
                files: session.stagedChanges.map { listed($0, staged: true) },
                checked: true,
                trailingDisabled: session.stagedChanges.isEmpty,
                onTrailing: { Task { await session.unstage(paths: session.stagedChanges.map(\.path)) } },
                menu: stagedMenu
            ),
            FileSection(
                id: "unstaged",
                title: String(localized: "Changes"),
                files: session.unstagedChanges.map { listed($0, staged: false) },
                checked: false,
                trailingDisabled: session.unstagedChanges.isEmpty,
                onTrailing: { Task { await session.stage(paths: session.unstagedChanges.map(\.path)) } },
                menu: unstagedMenu
            )
        ]
    }

    private var stagedMenu: [SectionMenuItem] {
        var menu = [
            SectionMenuItem(
                id: "commit",
                title: String(localized: "Commit"),
                disabled: !session.hasStaged,
                shortcut: KeyboardShortcut(.return, modifiers: .command),
                action: {
                    commitFailure = nil
                    showCommitComposer = true
                }
            )
        ]
        if DiffReviewer.isAvailable {
            menu.append(
                SectionMenuItem(
                    id: "review",
                    title: String(localized: "Brief Review"),
                    disabled: !session.hasStaged,
                    action: { showReview = true }
                )
            )
        }
        menu.append(
            SectionMenuItem(
                id: "stash",
                title: String(localized: "Stash"),
                disabled: session.changeCount == 0,
                action: { Task { await session.createStash(message: "") } }
            )
        )
        return menu
    }

    private var unstagedMenu: [SectionMenuItem] {
        [
            SectionMenuItem(
                id: "stash",
                title: String(localized: "Stash Unstaged Changes"),
                disabled: session.unstagedChanges.isEmpty,
                action: { Task { await session.createStash(message: "", unstagedOnly: true) } }
            ),
            SectionMenuItem(
                id: "discard",
                title: String(localized: "Discard Unstaged Changes"),
                destructive: true,
                disabled: session.unstagedChanges.isEmpty,
                action: { session.pendingConfirm = .discardAllUnstaged }
            )
        ]
    }

    private func listed(_ file: FileChange, staged: Bool) -> ListedFile {
        let kind = staged ? file.staged : file.unstaged
        return ListedFile(
            selection: FileSelection(path: file.path, staged: staged),
            displayPath: file.displayPath,
            statusLabel: kind.label
        )
    }
}

private struct CommitComposer: View {
    @Bindable var session: WorkspaceSession
    @Binding var failure: String?
    @Environment(\.dismiss) private var dismiss
    @State private var message: String
    @State private var amend = false
    @State private var headMessage: String?
    @State private var loadingHeadMessage = false
    @State private var headMessageLoadID = 0
    @State private var suggesting = false
    @State private var showReview = false

    init(session: WorkspaceSession, failure: Binding<String?>) {
        self.session = session
        _failure = failure
        _message = State(initialValue: session.commitMessage)
    }

    private var canAmend: Bool { !session.head.oid.isEmpty }

    private var messageIsEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSuggest: Bool {
        !amend && CommitMessageSuggester.isAvailable
    }

    private var canReview: Bool {
        DiffReviewer.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Commit", selection: Binding(
                get: { amend ? CommitDestination.previous : CommitDestination.new },
                set: { setAmend($0 == .previous) }
            )) {
                Text("New Commit").tag(CommitDestination.new)
                Text("Include in the previous commit")
                    .tag(CommitDestination.previous)
                    .disabled(!canAmend)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(session.isMutating)

            Text("Commit Message")
                .font(.headline)
            editor
            if let failure {
                CappedErrorText(text: failure)
            }
            HStack {
                if canSuggest {
                    Button(suggesting ? "Suggesting…" : "Suggest Message") {
                        Task { await suggest() }
                    }
                    .disabled(suggesting || !session.hasStaged || session.isMutating || loadingHeadMessage)
                }
                if canReview {
                    Button("Brief Review") {
                        showReview = true
                    }
                    .disabled(!session.hasStaged || session.isMutating || loadingHeadMessage)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Commit") {
                    Task { await submit() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(messageIsEmpty || !session.hasStaged || session.isMutating || loadingHeadMessage)
            }
        }
        .padding(20)
        .frame(width: 480)
        .sheet(isPresented: $showReview) {
            StagedReviewSheet(session: session)
        }
    }

    @ViewBuilder private var editor: some View {
        if loadingHeadMessage {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                }
        } else {
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 120)
                .disabled(suggesting)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                }
                .onChange(of: message) { _, newValue in
                    if !amend {
                        session.commitMessage = newValue
                    }
                }
        }
    }

    private func setAmend(_ on: Bool) {
        guard on != amend else { return }
        guard !on || canAmend else { return }
        failure = nil
        if on {
            amend = true
            if let headMessage {
                message = headMessage
            } else {
                headMessageLoadID += 1
                let id = headMessageLoadID
                loadingHeadMessage = true
                Task { await loadHeadMessage(id: id) }
            }
        } else {
            if headMessage != nil {
                headMessage = message
            }
            amend = false
            headMessageLoadID += 1
            loadingHeadMessage = false
            message = session.commitMessage
        }
    }

    private func loadHeadMessage(id: Int) async {
        defer {
            if id == headMessageLoadID {
                loadingHeadMessage = false
            }
        }
        do {
            let loaded = try await session.latestCommitMessage()
            guard id == headMessageLoadID else { return }
            headMessage = loaded
            if amend {
                message = loaded
            }
        } catch is CancellationError, is GitCancelled {
            return
        } catch {
            guard id == headMessageLoadID else { return }
            failure = (error as? GitFailure)?.message ?? error.localizedDescription
            amend = false
            message = session.commitMessage
        }
    }

    private func suggest() async {
        guard !suggesting, canSuggest, session.hasStaged else { return }
        suggesting = true
        defer { suggesting = false }
        failure = nil
        do {
            let diff = try await session.client.stagedDiffText()
            guard !Task.isCancelled else { return }
            guard let text = await CommitMessageSuggester.suggest(stagedDiff: diff) else {
                failure = String(localized: "Couldn't suggest a commit message.")
                return
            }
            guard !Task.isCancelled, !amend else { return }
            message = text
        } catch is CancellationError, is GitCancelled {
            return
        } catch {
            failure = (error as? GitFailure)?.message ?? error.localizedDescription
        }
    }

    private func submit() async {
        failure = nil
        if await session.commit(message: message, amend: amend) {
            dismiss()
        } else if let error = session.errorMessage {
            failure = error
            session.errorMessage = nil
        }
    }
}

/// 長いエラーでもシートが画面外まで伸びないよう、本文の高さで測って上限内に収める。
private struct CappedErrorText: View {
    var text: String
    var maxHeight: CGFloat = 140

    var body: some View {
        VerticallyCappedScroll(maxHeight: maxHeight) {
            content.hidden()
            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// スクロールビューは中身の高さを返さないので、隠した本文を測って表示高さを決める。
private struct VerticallyCappedScroll: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let probe = subviews[0]
        let content = probe.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: 0))
        subviews[1].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private enum CommitDestination: Hashable {
    case new
    case previous
}

struct ChangesDiffView: View {
    var session: WorkspaceSession

    var body: some View {
        let file = session.focusedWork
        FileDiffPane(
            title: file?.path,
            document: session.diff,
            isLoading: session.diffLoading,
            fileStaged: file?.staged,
            secondaryTitle: file?.staged == false ? String(localized: "Discard") : nil,
            actionsEnabled: !session.isMutating,
            onPrimaryFile: file == nil ? nil : {
                guard let file else { return }
                Task { await session.toggleStage([file]) }
            },
            onSecondaryFile: file?.staged == false ? {
                guard let file, let change = session.changes.first(where: { $0.path == file.path }) else { return }
                session.pendingConfirm = .discardUnstaged(change)
            } : nil,
            onOpenHistory: file == nil ? nil : {
                guard let file else { return }
                Task { await session.openFileHistory(file.path) }
            },
            onPrimaryHunk: file == nil ? nil : { hunk in
                Task { await session.stageHunk(hunk) }
            },
            onSecondaryHunk: file?.staged == false ? { hunk in
                session.pendingConfirm = .discardHunk(hunk.patch)
            } : nil,
            onStageLines: file == nil ? nil : { patch in
                Task { await session.stageLines(patch) }
            },
            onFixMissingNewline: file == nil ? nil : {
                guard let file else { return }
                Task { await session.appendTrailingNewline(path: file.path, staged: file.staged) }
            }
        )
    }
}
