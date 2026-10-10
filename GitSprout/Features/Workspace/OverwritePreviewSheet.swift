import SwiftUI

/// 強制プル・強制プッシュの前に、上書きで消えるコミットと、上書き前後のツリーの差分を見せる。
struct OverwritePreviewSheet: View {
    var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    private var range: (before: String, after: String)? {
        session.overwritePreview?.overwrite
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let range {
                    Text(verbatim: "\(range.before) → \(range.after)")
                        .font(.headline)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if let confirm = session.overwritePreview {
                    // 破壊的な操作なので、確認ダイアログと同じくキーボードでは実行させない
                    Button(confirm.confirmTitle, role: .destructive) {
                        Task { await session.performOverwritePreview() }
                    }
                    .disabled(session.isMutating || session.overwriteFilesLoading)
                }
            }
            .padding(12)
            Divider()
            ChangedFilesSplit(
                files: session.overwriteFiles,
                filesCapped: session.overwriteFilesCapped,
                filesLoading: session.overwriteFilesLoading,
                listID: range.map { "\($0.before)..\($0.after)" } ?? "overwrite",
                selectedPath: session.overwritePath,
                document: session.overwriteDiff,
                diffLoading: session.overwriteDiffLoading,
                isMutating: session.isMutating,
                commitOID: range?.after,
                onSelect: { path in
                    Task { await session.selectOverwriteFile(path) }
                },
                onOpenHistory: { path in
                    Task { await session.openFileHistory(path) }
                },
                sectionTitle: String(localized: "Changed Files")
            ) {
                lostCommits
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

    @ViewBuilder
    private var lostCommits: some View {
        if let range, !session.overwriteFilesLoading {
            VStack(alignment: .leading, spacing: 4) {
                Text("Commits removed from \(range.before)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.overwriteLostCommits.isEmpty {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.overwriteLostCommits) { commit in
                                HStack(spacing: 6) {
                                    Text(verbatim: String(commit.oid.prefix(7)))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(commit.subject.isEmpty ? String(localized: "(No message)") : commit.subject)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .textSelection(.enabled)
                            }
                            if session.overwriteLostCommitsCapped {
                                Text("And more…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
        }
    }
}
