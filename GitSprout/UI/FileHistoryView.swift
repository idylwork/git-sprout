//
//  FileHistoryView.swift
//  GitSprout
//

import SwiftUI

struct FileHistoryView: View {
    var session: WorkspaceSession
    @Environment(\.keyboardFocus) private var keyboardFocus

    var body: some View {
        VStack(spacing: 0) {
            if session.fileHistoryLoading && session.fileCommits.isEmpty {
                ProgressView("Loading History…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.fileCommits.isEmpty {
                ContentUnavailableView("No History for This File", systemImage: "clock")
            } else {
                ScrollViewReader { proxy in
                    List(session.fileCommits) { commit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject.isEmpty ? String(localized: "(No message)") : commit.subject)
                                .lineLimit(1)
                            HStack {
                                Text(String(commit.oid.prefix(7)))
                                Text(commit.authoredAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            keyboardFocus?.target = .fileHistory
                            guard session.selectedFileRevision != commit.oid else { return }
                            Task { await session.selectFileRevision(commit.oid) }
                        }
                        .onAppear {
                            Task { await session.prefetchFileHistory(oid: commit.oid) }
                        }
                        .listRowBackground(session.selectedFileRevision == commit.oid ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .keyboardTarget(.fileHistory, focusable: true)
                    .selectionArrows(target: .fileHistory) { delta, _ in
                        moveRevision(delta, proxy: proxy)
                    }
                    .onAppear { keyboardFocus?.target = .fileHistory }
                }
                if session.fileHistoryHasMore {
                    Button(String(localized: session.fileHistoryLoadingMore ? "Loading…" : "Load More")) {
                        Task { await session.loadMoreFileHistory() }
                    }
                    .disabled(session.fileHistoryLoadingMore)
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func moveRevision(_ delta: Int, proxy: ScrollViewProxy) {
        let ids = session.fileCommits.map(\.oid)
        guard let index = SelectionStep.index(of: session.selectedFileRevision, in: ids, delta: delta) else { return }
        let oid = ids[index]
        guard oid != session.selectedFileRevision else { return }
        proxy.scrollTo(oid, anchor: .center)
        Task { await session.selectFileRevision(oid) }
    }
}

struct FileBodyView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        Group {
            switch session.fileBodyMode {
            case .content:
                blob
            case .parentDiff:
                DiffView(document: session.fileParentDiff, isLoading: session.fileBodyLoading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("Show", selection: $session.fileBodyMode) {
                    ForEach(FileBodyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
            }
            .frame(maxWidth: .infinity)
            .background(.windowBackground)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: session.fileBodyMode) { _, _ in
                Task { await session.loadFileBody() }
            }
        }
    }

    @ViewBuilder
    private var blob: some View {
        if session.fileBodyLoading && session.fileBlob == nil {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let blob = session.fileBlob {
            if let image = blob.image {
                FittedImage(data: image)
            } else if blob.truncated {
                ContentUnavailableView("File is too large to display.", systemImage: "exclamationmark.triangle")
            } else if blob.binary {
                ContentUnavailableView("Binary File", systemImage: "doc")
            } else {
                ScrollView {
                    Text(blob.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            ContentUnavailableView("Select a Revision", systemImage: "clock")
        }
    }
}

struct FileHistorySheet: View {
    var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(session.fileHistoryPath ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Done") {
                    dismiss()
                }
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HSplitView {
                FileHistoryView(session: session)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                FileBodyView(session: session)
                    .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1080, height: 680)
        .sheetKeyboardScope(.fileHistory)
    }
}
