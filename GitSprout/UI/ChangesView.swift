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
                menu: [
                    SectionMenuItem(
                        id: "commit",
                        title: String(localized: "Commit"),
                        disabled: !session.hasStaged,
                        shortcut: KeyboardShortcut(.return, modifiers: .command),
                        action: {
                            commitFailure = nil
                            showCommitComposer = true
                        }
                    ),
                    SectionMenuItem(
                        id: "stash",
                        title: String(localized: "Stash"),
                        disabled: session.changeCount == 0,
                        action: { Task { await session.createStash(message: "") } }
                    )
                ]
            ),
            FileSection(
                id: "unstaged",
                title: String(localized: "Changes"),
                files: session.unstagedChanges.map { listed($0, staged: false) },
                checked: false,
                trailingDisabled: session.unstagedChanges.isEmpty,
                onTrailing: { Task { await session.stage(paths: session.unstagedChanges.map(\.path)) } },
                menu: [
                    SectionMenuItem(
                        id: "discard",
                        title: String(localized: "Discard Unstaged Changes"),
                        destructive: true,
                        disabled: session.unstagedChanges.isEmpty,
                        action: { session.pendingConfirm = .discardAllUnstaged }
                    )
                ]
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

    init(session: WorkspaceSession, failure: Binding<String?>) {
        self.session = session
        _failure = failure
        _message = State(initialValue: session.commitMessage)
    }

    private var canAmend: Bool { !session.head.oid.isEmpty }

    private var messageIsEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
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
            }
        )
    }
}
