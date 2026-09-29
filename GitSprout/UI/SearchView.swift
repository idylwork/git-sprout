//
//  SearchView.swift
//  GitSprout
//

import SwiftUI

struct SearchView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.keyboardFocus) private var keyboardFocus
    @State private var selectedPath: String?
    @State private var selectedContentID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $session.searchKind) {
                    ForEach(SearchKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140, height: 22)
                TextField("Search", text: $session.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(height: 22)
                    .onSubmit { Task { await session.search() } }
                Button("Search") {
                    Task { await session.search() }
                }
                .fixedSize()
                .disabled(session.searchLoading || session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if session.searchCapped {
                Text(String(localized: "Stopped after \(GitLimits.searchLimit) results."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            Group {
                if session.searchLoading {
                    ProgressView("Searching…")
                } else {
                    results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var results: some View {
        switch session.searchKind {
        case .message:
            if session.commitHits.isEmpty {
                ContentUnavailableView("Search Commits", systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    List(session.commitHits) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).lineLimit(1)
                            Text(String(commit.oid.prefix(7)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusSearch()
                            guard session.selectedSearchCommit != commit.oid else { return }
                            Task { await session.selectSearchCommit(commit.oid) }
                        }
                        .listRowBackground(session.selectedSearchCommit == commit.oid ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .searchKeys(proxy: proxy, move: move)
                }
            }
        case .path:
            if session.pathHits.isEmpty {
                ContentUnavailableView("Search Paths", systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    List(session.pathHits, id: \.self) { path in
                        Text(path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                focusSearch()
                                selectedPath = path
                                Task { await session.openFileHistory(path) }
                            }
                            .listRowBackground(selectedPath == path ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .searchKeys(proxy: proxy, move: move)
                }
            }
        case .content:
            if session.contentHits.isEmpty {
                ContentUnavailableView("Search File Contents", systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    List(session.contentHits) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hit.path):\(hit.line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(hit.text).lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusSearch()
                            selectedContentID = hit.id
                            Task { await session.openFileHistory(hit.path) }
                        }
                        .listRowBackground(selectedContentID == hit.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .searchKeys(proxy: proxy, move: move)
                }
            }
        }
    }

    private func focusSearch() {
        keyboardFocus?.target = .search
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        switch session.searchKind {
        case .message:
            let ids = session.commitHits.map(\.oid)
            guard let index = SelectionStep.index(of: session.selectedSearchCommit, in: ids, delta: delta) else { return }
            let oid = ids[index]
            guard oid != session.selectedSearchCommit else { return }
            proxy.scrollTo(oid, anchor: .center)
            Task { await session.selectSearchCommit(oid) }
        case .path:
            guard let index = SelectionStep.index(of: selectedPath, in: session.pathHits, delta: delta) else { return }
            let path = session.pathHits[index]
            guard path != selectedPath else { return }
            selectedPath = path
            proxy.scrollTo(path, anchor: .center)
        case .content:
            let ids = session.contentHits.map(\.id)
            guard let index = SelectionStep.index(of: selectedContentID, in: ids, delta: delta) else { return }
            let id = ids[index]
            guard id != selectedContentID else { return }
            selectedContentID = id
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private extension View {
    func searchKeys(proxy: ScrollViewProxy, move: @escaping (Int, ScrollViewProxy) -> Void) -> some View {
        keyboardTarget(.search)
            .selectionArrows(target: .search) { delta in
                move(delta, proxy)
            }
    }
}

struct SearchDetailView: View {
    var session: WorkspaceSession

    var body: some View {
        if session.searchKind == .message, let oid = session.selectedSearchCommit {
            VSplitView {
                FileActionList(
                    sections: [
                        FileSection(
                            id: "search",
                            title: String(localized: "This Commit"),
                            files: session.searchCommitFiles.map { file in
                                ListedFile(
                                    selection: FileSelection(path: file.path, staged: false, commitOID: oid),
                                    displayPath: file.displayPath,
                                    statusLabel: file.code
                                )
                            }
                        )
                    ],
                    isMutating: session.isMutating,
                    allowsDiscard: false,
                    onFocus: { file in
                        guard let file else { return }
                        Task { await session.selectSearchCommitFile(file.path) }
                    },
                    onToggle: { files in
                        Task { await session.toggleStage(files) }
                    },
                    onDiscard: nil,
                    onOpenHistory: { path in
                        Task { await session.openFileHistory(path) }
                    }
                )
                .id(oid)
                FileDiffPane(
                    title: session.searchCommitPath,
                    document: session.searchDiff,
                    isLoading: false,
                    fileStaged: session.searchCommitPath == nil ? nil : false,
                    secondaryTitle: nil,
                    actionsEnabled: !session.isMutating,
                    onPrimaryFile: session.searchCommitPath == nil ? nil : {
                        guard let path = session.searchCommitPath else { return }
                        Task { await session.toggleStage([FileSelection(path: path, staged: false, commitOID: oid)]) }
                    },
                    onSecondaryFile: nil,
                    onOpenHistory: nil,
                    onPrimaryHunk: session.searchCommitPath == nil ? nil : { hunk in
                        Task { await session.stageCommitHunk(hunk) }
                    },
                    onSecondaryHunk: nil,
                    onStageLines: session.searchCommitPath == nil ? nil : { patch in
                        Task { await session.stageCommitLines(patch) }
                    }
                )
            }
        } else {
            ContentUnavailableView("Select a Result", systemImage: "magnifyingglass")
        }
    }
}
