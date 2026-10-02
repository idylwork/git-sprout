//
//  DiffReview.swift
//  GitSprout
//

import Foundation
import FoundationModels

struct DiffReview: Equatable, Sendable {
    var summary: String?
    var risk: String?
    var findings: [DiffReviewFinding]
}

struct ReviewSourceLine: Equatable, Sendable, Identifiable {
    var id: Int
    var oldNumber: Int?
    var newNumber: Int?
    var kind: DiffLine.Kind
    var text: String

    /// プロンプトと指摘が指す行番号。追加と文脈は新しい側、削除は古い側。
    var cite: Int? {
        switch kind {
        case .addition, .context: newNumber
        case .deletion: oldNumber
        case .meta: nil
        }
    }
}

struct DiffReviewFinding: Equatable, Sendable, Identifiable {
    var path: String
    var lines: [ReviewSourceLine]
    var comment: String
    var id: String { "\(path):\(lines.first?.id ?? 0)\n\(comment)" }
}

struct ReviewHunk: Equatable, Sendable, Identifiable {
    var index: Int
    var path: String
    var lines: [ReviewSourceLine]
    var id: Int { index }

    var changedLines: [ReviewSourceLine] {
        lines.filter { $0.kind == .addition || $0.kind == .deletion }
    }
}

/// ステージ済み差分の中身から、概要と、見えるときだけのリスクを作る。
nonisolated enum DiffReviewPrompt {
    static let characterLimit = 2_500
    static let findingLimit = 6

    static func instructions(for language: CommitMessageLanguage) -> String {
        let languageLine: String
        switch language {
        case .english:
            languageLine = "Write the overview and the risk entirely in English."
        case .japanese:
            languageLine = "Write the overview and the risk entirely in Japanese. Do not write them in English."
        }
        return """
        Describe what the change does.
        Mention a risk only when one is visible. Otherwise leave it blank.
        Do not name files or quote code.
        \(languageLine)
        """
    }

    /// ファイル名と差分ヘッダを除いた変更本文。長いときは先頭だけ残す。
    static func changeExcerpt(_ diff: String, limit: Int = characterLimit) -> String {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var kept: [String] = []
        let source: String
        if let range = trimmed.range(of: "diff --git ") {
            let preamble = trimmed[..<range.lowerBound]
            for line in preamble.split(separator: "\n") {
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                if raw.contains(" changed") { kept.append(raw) }
            }
            source = String(trimmed[range.lowerBound...])
        } else {
            source = trimmed
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.hasPrefix("diff --git ") || raw.hasPrefix("index ")
                || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ")
                || raw.hasPrefix("new file") || raw.hasPrefix("deleted file")
                || raw.hasPrefix("rename ") || raw.hasPrefix("similarity ")
                || raw.hasPrefix("dissimilarity ") || raw.hasPrefix("old mode")
                || raw.hasPrefix("new mode") || raw.hasPrefix("copy ")
                || raw.hasPrefix("GIT binary") {
                continue
            }
            if raw.hasPrefix("Binary files ") {
                kept.append("A binary file changed.")
                continue
            }
            kept.append(raw)
        }
        let excerpt = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return "" }
        guard excerpt.count > limit else { return excerpt }
        let head = excerpt.prefix(limit)
        let partial: Substring
        if let newline = head.lastIndex(of: "\n"), newline != head.startIndex {
            partial = head[..<newline]
        } else {
            partial = head
        }
        return partial + "\n\n" + CommitMessagePrompt.omittedNote
    }

    static func prompt(for diff: String, language: CommitMessageLanguage = .english) -> String? {
        let excerpt = changeExcerpt(diff)
        guard !excerpt.isEmpty else { return nil }
        let languageLine: String
        switch language {
        case .english:
            languageLine = "Write the overview in English."
        case .japanese:
            languageLine = "Write the overview in Japanese, not in English."
        }
        return """
        Describe this change.
        \(languageLine)

        \(excerpt)
        """
    }

    /// 文脈行も含めてハンクを読む。統計は含めない。
    static func parseHunks(_ diff: String) -> [ReviewHunk] {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "diff --git ") else { return [] }
        let patch = trimmed[range.lowerBound...]
        var path = ""
        var hunks: [ReviewHunk] = []
        var newLine = 0
        var oldLine = 0
        var inHunk = false
        var lines: [ReviewSourceLine] = []
        var nextID = 0

        func flush() {
            let hasChange = lines.contains { $0.kind == .addition || $0.kind == .deletion }
            if !path.isEmpty, hasChange {
                hunks.append(ReviewHunk(index: hunks.count + 1, path: path, lines: lines))
            }
            lines = []
        }

        func append(old: Int?, new: Int?, kind: DiffLine.Kind, text: String) {
            lines.append(ReviewSourceLine(id: nextID, oldNumber: old, newNumber: new, kind: kind, text: text))
            nextID += 1
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.hasPrefix("diff --git ") {
                flush()
                inHunk = false
                path = filePath(from: raw) ?? ""
                continue
            }
            if raw.hasPrefix("@@") {
                flush()
                if let header = hunkHeader(raw) {
                    newLine = header.newStart
                    oldLine = header.oldStart
                    inHunk = true
                } else {
                    inHunk = false
                }
                continue
            }
            guard inHunk else { continue }
            if raw.hasPrefix("\\") {
                continue
            }
            if raw.hasPrefix("+") {
                append(old: nil, new: newLine, kind: .addition, text: String(raw.dropFirst()))
                newLine += 1
            } else if raw.hasPrefix("-") {
                append(old: oldLine, new: nil, kind: .deletion, text: String(raw.dropFirst()))
                oldLine += 1
            } else {
                let text = raw.isEmpty ? "" : String(raw.dropFirst())
                append(old: oldLine, new: newLine, kind: .context, text: text)
                newLine += 1
                oldLine += 1
            }
        }
        flush()
        return hunks
    }

    /// 指摘された行の前後1行を、差分の実体から切り出す。
    static func review(
        summary: String,
        risk: String = "",
        comments: [(hunk: Int, line: Int, comment: String)],
        hunks: [ReviewHunk]
    ) -> DiffReview? {
        let summary = usableSummary(summary)
        let risk = usableRisk(risk)
        let cited = comments.compactMap { comment -> CitedLine? in
            guard let hunk = hunks.first(where: { $0.index == comment.hunk }),
                  let index = lineIndex(comment.line, in: hunk),
                  let text = usableComment(comment.comment, line: hunk.lines[index]) else { return nil }
            return CitedLine(hunk: hunk, index: index, comment: text)
        }.sorted { lhs, rhs in
            if lhs.hunk.index != rhs.hunk.index { return lhs.hunk.index < rhs.hunk.index }
            return lhs.index < rhs.index
        }
        var findings: [DiffReviewFinding] = []
        var cluster: [CitedLine] = []
        func flushCluster() {
            guard findings.count < findingLimit, let window = snippet(cluster) else { return }
            findings.append(window)
        }
        for item in cited {
            if let last = cluster.last,
               last.hunk.index == item.hunk.index,
               item.index <= last.index + 2 {
                if !cluster.contains(where: { $0.index == item.index && $0.comment == item.comment }) {
                    cluster.append(item)
                }
            } else {
                flushCluster()
                cluster = [item]
            }
        }
        flushCluster()
        guard summary != nil || risk != nil || !findings.isEmpty else { return nil }
        return DiffReview(summary: summary, risk: risk, findings: findings)
    }

    private struct CitedLine {
        var hunk: ReviewHunk
        var index: Int
        var comment: String
    }

    private static func snippet(_ cluster: [CitedLine]) -> DiffReviewFinding? {
        guard let hunk = cluster.first?.hunk,
              let lower = cluster.map(\.index).min(),
              let upper = cluster.map(\.index).max() else { return nil }
        let start = max(0, lower - 1)
        let end = min(hunk.lines.count - 1, upper + 1)
        var comments: [String] = []
        for item in cluster where !comments.contains(item.comment) {
            comments.append(item.comment)
        }
        guard !comments.isEmpty else { return nil }
        return DiffReviewFinding(path: hunk.path, lines: Array(hunk.lines[start...end]), comment: comments.joined(separator: "\n"))
    }

    private static func lineIndex(_ line: Int, in hunk: ReviewHunk) -> Int? {
        if let index = hunk.lines.firstIndex(where: { $0.kind == .addition && $0.newNumber == line }) {
            return index
        }
        if let index = hunk.lines.firstIndex(where: { $0.kind == .deletion && $0.oldNumber == line }) {
            return index
        }
        return nil
    }

    private static func usableSummary(_ raw: String) -> String? {
        guard let text = CommitMessagePrompt.cleanedMessage(polished(raw)),
              !CommitMessagePrompt.looksLikeDiff(text),
              !echoesInstructions(text) else { return nil }
        return text
    }

    /// 空欄や「リスクはない」だけの返答は、リスクの言及として出さない。
    private static func usableRisk(_ raw: String) -> String? {
        guard let text = CommitMessagePrompt.cleanedMessage(polished(raw)),
              !CommitMessagePrompt.looksLikeDiff(text),
              !echoesInstructions(text),
              !dismissesRisk(text) else { return nil }
        return text
    }

    /// 制御トークンと、文末に漏れた閉じ括弧を除く。
    private static func polished(_ raw: String) -> String {
        var text = raw.replacing(/(?i)<ctrl\d+>/, with: "")
        var removedBrace = false
        while let last = text.last, last == "}" || last == "`" || last.isWhitespace {
            if last == "}" { removedBrace = true }
            text.removeLast()
        }
        if removedBrace, text.last == "」" {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dismissesRisk(_ text: String) -> Bool {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let blanks: Set<String> = [
            "none", "no", "n/a", "na", "nothing", "no risk", "no concern",
            "blank", "empty", "-", "なし", "特になし", "特にありません",
            "リスクはありません", "リスクはない", "問題ありません", "問題はない",
            "特にリスクはありません", "特にリスクはない",
        ]
        return blanks.contains(sample)
    }

    private static func usableComment(_ raw: String, line: ReviewSourceLine) -> String? {
        guard let text = CommitMessagePrompt.cleanedMessage(polished(raw)),
              !CommitMessagePrompt.looksLikeDiff(text),
              !echoesInstructions(text) else { return nil }
        guard line.text.trimmingCharacters(in: .whitespaces) != text else { return nil }
        return text
    }

    /// モデルが依頼文を要約して返したときは捨てる。
    private static func echoesInstructions(_ text: String) -> Bool {
        let sample = text.lowercased()
        let phrases = [
            "two or three",
            "2〜3",
            "2～3",
            "総評は",
            "準備状況",
            "未完成のハンク",
            "すべての指摘",
            "these instructions",
            "hunk number",
            "do not describe",
            "チェックが削除",
            "デフォルトが変更",
            "条件のデフォルト",
            "one or two sentences",
            "what the changed lines do",
            "finding cites",
            "line it replaces",
            "words from this line",
            "do not name files",
            "leave it blank",
            "mention a risk",
            "what the change does",
        ]
        if phrases.contains(where: { sample.contains($0.lowercased()) }) { return true }
        if repeatsItself(sample) { return true }
        return sharesInstructionPhrase(sample)
    }

    /// 同じ文がもう一度出てきた返答は、生成の繰り返しとみなす。
    private static func repeatsItself(_ sample: String) -> Bool {
        let compact = sample.filter { $0.isLetter || $0.isNumber }
        let width = 24
        guard compact.count >= width * 2 else { return false }
        let chars = Array(compact)
        var seen: Set<String> = []
        for index in 0...(chars.count - width) {
            let window = String(chars[index..<(index + width)])
            if !seen.insert(window).inserted { return true }
        }
        return false
    }

    /// 依頼文の連続した語をそのまま返した文は、レビューではない。
    private static func sharesInstructionPhrase(_ sample: String) -> Bool {
        let source = (instructions(for: .english) + "\n" + instructions(for: .japanese)).lowercased()
        let words = sample.split(separator: " ").map(String.init)
        let width = 6
        guard words.count >= width else { return false }
        for index in 0...(words.count - width) {
            let window = words[index..<(index + width)].joined(separator: " ")
            if source.contains(window) { return true }
        }
        return false
    }

    private static func filePath(from line: String) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        let marker = rest.range(of: " b/") ?? rest.range(of: "\"b/")
        guard let marker else { return nil }
        var path = String(rest[marker.upperBound...])
        if path.hasSuffix("\"") { path.removeLast() }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let pattern = #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func value(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
            return Int(line[swiftRange])
        }
        guard let oldStart = value(1), let newStart = value(2) else { return nil }
        return (oldStart, newStart)
    }
}

nonisolated enum DiffReviewer {
    static var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    static func review(stagedDiff: String) async -> DiffReview? {
        let language = AppSettings.commitMessageLanguage
        guard let prompt = DiffReviewPrompt.prompt(for: stagedDiff, language: language) else { return nil }
        guard #available(macOS 26, *) else { return nil }
        return await AppleIntelligenceDiffReview.review(
            prompt: prompt,
            instructions: DiffReviewPrompt.instructions(for: language),
            language: language
        )
    }
}

@available(macOS 26, *)
@Generable
nonisolated private struct EnglishDiffReview {
    @Guide(description: "Overview.")
    var summary: String

    @Guide(description: "Risk.")
    var risk: String
}

@available(macOS 26, *)
@Generable
nonisolated private struct JapaneseDiffReview {
    @Guide(description: "Overview.")
    var summary: String

    @Guide(description: "Risk.")
    var risk: String
}

@available(macOS 26, *)
private nonisolated enum AppleIntelligenceDiffReview {
    static func review(
        prompt: String,
        instructions: String,
        language: CommitMessageLanguage
    ) async -> DiffReview? {
        let job = Task.detached(priority: .userInitiated) { () -> DiffReview? in
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 400)
            do {
                switch language {
                case .english:
                    let content = try await session.respond(to: prompt, generating: EnglishDiffReview.self, options: options).content
                    return DiffReviewPrompt.review(summary: content.summary, risk: content.risk, comments: [], hunks: [])
                case .japanese:
                    let content = try await session.respond(to: prompt, generating: JapaneseDiffReview.self, options: options).content
                    return DiffReviewPrompt.review(summary: content.summary, risk: content.risk, comments: [], hunks: [])
                }
            } catch {
                return nil
            }
        }
        return await withTaskCancellationHandler {
            let value = await job.value
            return Task.isCancelled ? nil : value
        } onCancel: {
            job.cancel()
        }
    }
}
