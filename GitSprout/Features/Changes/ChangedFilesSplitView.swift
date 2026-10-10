import SwiftUI

/// 変更ファイルの一覧と、選択したファイルの差分。履歴のコミットと、ブランチ差分のシートで共用する。
struct ChangedFilesSplit<Header: View>: View {
    var files: [PathStatus]
    var filesCapped: Bool
    var filesLoading: Bool
    var listID: String
    var selectedPath: String?
    var document: DiffDocument?
    var diffLoading: Bool
    var isMutating: Bool
    var commitOID: String?
    var onSelect: (String) -> Void
    var onOpenHistory: (String) -> Void
    var sectionTitle = String(localized: "Changed Files")
    var menu: [SectionMenuItem] = []
    @ViewBuilder var header: () -> Header

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header()
                if filesCapped {
                    Text("Too many changed files to show them all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                fileList
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            FileDiffPane(
                title: diffTitle,
                document: document,
                isLoading: diffLoading,
                fileStaged: nil,
                secondaryTitle: nil,
                actionsEnabled: !isMutating,
                onPrimaryFile: nil,
                onSecondaryFile: nil,
                onOpenHistory: selectedPath == nil ? nil : {
                    guard let selectedPath else { return }
                    onOpenHistory(selectedPath)
                },
                onPrimaryHunk: nil,
                onSecondaryHunk: nil,
                onStageLines: nil
            )
            .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffTitle: String? {
        guard let selectedPath else { return nil }
        return files.first { $0.path == selectedPath }?.displayPath ?? selectedPath
    }

    @ViewBuilder
    private var fileList: some View {
        if filesLoading && files.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileActionList(
                sections: [
                    FileSection(
                        id: listID,
                        title: sectionTitle,
                        files: files.map { file in
                            ListedFile(
                                selection: FileSelection(path: file.path, staged: false, commitOID: commitOID),
                                displayPath: file.displayPath,
                                statusLabel: file.code
                            )
                        },
                        menu: menu
                    )
                ],
                isMutating: isMutating,
                allowsStage: false,
                allowsDiscard: false,
                onFocus: { file in
                    guard let file else { return }
                    onSelect(file.path)
                },
                onToggle: { _ in },
                onDiscard: nil,
                onOpenHistory: onOpenHistory
            )
            .id(listID)
        }
    }
}

struct RangeDiffSheet: View {
    var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let title = session.rangeDiffTitle {
                    Text(verbatim: title)
                        .font(.headline)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Done") {
                    dismiss()
                }
            }
            .padding(12)
            Divider()
            ChangedFilesSplit(
                files: session.rangeFiles,
                filesCapped: session.rangeFilesCapped,
                filesLoading: session.rangeFilesLoading,
                listID: session.rangeBase ?? "range",
                selectedPath: session.rangePath,
                document: session.rangeDiff,
                diffLoading: session.rangeDiffLoading,
                isMutating: session.isMutating,
                commitOID: session.rangeBase,
                onSelect: { path in
                    Task { await session.selectRangeFile(path) }
                },
                onOpenHistory: { path in
                    Task { await session.openFileHistory(path) }
                }
            ) {
                EmptyView()
            }
        }
        .frame(width: 1080, height: 680)
        .sheetKeyboardScope(.files)
        .sheet(
            isPresented: Binding(
                get: { session.fileHistoryPath != nil },
                set: { if !$0 { session.closeFileHistory() } }
            )
        ) {
            FileHistorySheet(session: session)
        }
    }
}
