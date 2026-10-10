import SwiftUI

/// ステージ済み差分の簡易レビュー。コミット画面とステージ済みメニューの両方から開く。
struct StagedReviewSheet: View {
    var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var review: DiffReview?
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brief Review")
                .font(.headline)
            content
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Reviewing…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let review {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let summary = review.summary {
                        Text("Overview")
                            .font(.headline)
                        Text(summary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let risk = review.risk {
                        Text("Risk")
                            .font(.headline)
                        Text(risk)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(review.findings) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            ReviewDiffBlock(path: finding.path, lines: finding.lines)
                            Text(finding.comment)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)
        } else {
            Text(failure ?? String(localized: "Couldn't review the staged changes."))
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            let diff = try await session.client.stagedDiffText()
            guard !Task.isCancelled else { return }
            guard let review = await DiffReviewer.review(stagedDiff: diff) else {
                guard !Task.isCancelled else { return }
                failure = String(localized: "Couldn't review the staged changes.")
                loading = false
                return
            }
            guard !Task.isCancelled else { return }
            self.review = review
            loading = false
        } catch is CancellationError, is GitCancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? GitFailure)?.message ?? error.localizedDescription
            loading = false
        }
    }
}

/// 指摘の対象行と、その前後1行。行番号と追加・削除の地色は差分ビューに揃える。
private struct ReviewDiffBlock: View {
    var path: String
    var lines: [ReviewSourceLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.14))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    row(line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        }
    }

    private var oldDigits: Int {
        max(String(lines.compactMap(\.oldNumber).max() ?? 0).count, 1)
    }

    private var newDigits: Int {
        max(String(lines.compactMap(\.newNumber).max() ?? 0).count, 1)
    }

    private func row(_ line: ReviewSourceLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: gutter(line.oldNumber, digits: oldDigits))
                .foregroundStyle(.secondary)
            Text(verbatim: gutter(line.newNumber, digits: newDigits))
                .foregroundStyle(.secondary)
            Text(verbatim: marker(line.kind))
                .foregroundStyle(markerColor(line.kind))
            Text(verbatim: line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
    }

    private func gutter(_ value: Int?, digits: Int) -> String {
        guard let value else { return String(repeating: " ", count: digits) }
        let text = String(value)
        guard text.count < digits else { return text }
        return String(repeating: " ", count: digits - text.count) + text
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .meta: " "
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .context, .meta: .secondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.16)
        case .deletion: Color.red.opacity(0.16)
        case .meta: Color.secondary.opacity(0.08)
        case .context: .clear
        }
    }
}
