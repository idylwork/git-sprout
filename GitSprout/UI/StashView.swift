//
//  StashView.swift
//  GitSprout
//

import SwiftUI

struct StashView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.keyboardFocus) private var keyboardFocus

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Stash Message", text: $session.stashMessage)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(height: 22)
                Button("Create") {
                    Task { await session.createStash() }
                }
                .fixedSize()
                .disabled(session.isMutating)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Group {
                if session.stashes.isEmpty {
                    ContentUnavailableView("No Stashes", systemImage: "archivebox")
                } else {
                    ScrollViewReader { proxy in
                        List(session.stashes) { stash in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stash.subject)
                                        .lineLimit(1)
                                    Text(stash.ref)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Apply") {
                                    Task { await session.applyStash(stash.ref, pop: false) }
                                }
                                .disabled(session.isMutating)
                                Button("Apply and Drop") {
                                    Task { await session.applyStash(stash.ref, pop: true) }
                                }
                                .disabled(session.isMutating)
                                Button("Drop", role: .destructive) {
                                    session.pendingConfirm = .dropStash(stash.ref)
                                }
                                .disabled(session.isMutating)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                keyboardFocus?.target = .stashes
                                guard session.selectedStash != stash.ref else { return }
                                Task { await session.selectStash(stash.ref) }
                            }
                            .listRowBackground(session.selectedStash == stash.ref ? Color.accentColor.opacity(0.18) : Color.clear)
                        }
                        .keyboardTarget(.stashes)
                        .selectionArrows(target: .stashes) { delta, _ in
                            moveStash(delta, proxy: proxy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func moveStash(_ delta: Int, proxy: ScrollViewProxy) {
        let refs = session.stashes.map(\.ref)
        guard let index = SelectionStep.index(of: session.selectedStash, in: refs, delta: delta) else { return }
        let stash = session.stashes[index]
        guard stash.ref != session.selectedStash else { return }
        proxy.scrollTo(stash.id, anchor: .center)
        Task { await session.selectStash(stash.ref) }
    }
}

struct StashDetailView: View {
    var session: WorkspaceSession

    var body: some View {
        if session.selectedStash == nil {
            ContentUnavailableView("Select a Stash", systemImage: "archivebox")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                stashFiles
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                diffPane
                    .frame(minWidth: 280, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var stashFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.stashFilesCapped {
                Text("Too many changed files to show them all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            if session.stashFilesLoading && session.stashFiles.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FileActionList(
                    sections: [
                        FileSection(
                            id: "stash",
                            title: String(localized: "Changed Files"),
                            files: session.stashFiles.map { file in
                                ListedFile(
                                    selection: FileSelection(path: file.path, staged: false),
                                    displayPath: file.displayPath,
                                    statusLabel: file.code
                                )
                            }
                        )
                    ],
                    isMutating: session.isMutating,
                    allowsStage: false,
                    allowsDiscard: false,
                    onFocus: { file in
                        guard let file else { return }
                        Task { await session.selectStashFile(file.path) }
                    },
                    onToggle: { _ in },
                    onDiscard: nil,
                    onOpenHistory: { path in
                        Task { await session.openFileHistory(path) }
                    }
                )
                .id(session.selectedStash)
            }
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if session.selectedStashPath == nil {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileDiffPane(
                title: session.stashFiles.first { $0.path == session.selectedStashPath }?.displayPath,
                document: session.stashDiff,
                isLoading: session.stashDiffLoading,
                fileStaged: nil,
                secondaryTitle: nil,
                actionsEnabled: !session.isMutating,
                onPrimaryFile: nil,
                onSecondaryFile: nil,
                onOpenHistory: {
                    guard let path = session.selectedStashPath else { return }
                    Task { await session.openFileHistory(path) }
                },
                onPrimaryHunk: nil,
                onSecondaryHunk: nil,
                onStageLines: nil
            )
        }
    }
}
