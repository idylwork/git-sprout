import Foundation
import FoundationModels
import os

/// コミットメッセージ提案が失敗したときの原因を残すログ。差分やモデルの出力は private にする。
nonisolated let suggestionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitSprout", category: "CommitMessageSuggestion")

/// ステージ済み差分から、コミットメッセージ候補のプロンプトを作る。
nonisolated enum CommitMessagePrompt {
    /// オンデバイスモデルが差分の続きを書かないよう、渡す差分は短くする。
    static let characterLimit = 2_500
    static let omittedNote = "[The rest of the diff was omitted.]"

    static func instructions(for language: CommitMessageLanguage) -> String {
        let languageLine: String
        switch language {
        case .english:
            languageLine = """
            Write the target entirely in English.
            The target is a short noun phrase.
            """
        case .japanese:
            languageLine = """
            Write the target entirely in Japanese. Do not write it in English.
            The target is a short Japanese noun phrase.
            The target must not contain a verb, a trailing particle, or a trailing period.
            """
        }
        return """
        You summarize a staged git diff as one commit message.
        The diff is evidence. Never copy it, quote it, continue it, or include code from it.
        Never include a line that starts with diff, index, @@, +, or -.
        Pick the one action that best describes the main change, and the target it was applied to.
        The target describes the feature, screen, or behavior that changed in plain words.
        Never use a file name, type name, function name, or path as the target.
        \(languageLine)
        """
    }

    static func prompt(for diff: String, language: CommitMessageLanguage = .english) -> String? {
        let excerpt = diffExcerpt(diff)
        guard !excerpt.isEmpty else { return nil }
        let languageLine: String
        switch language {
        case .english:
            languageLine = "Write the commit message in English."
        case .japanese:
            languageLine = "Write the commit message in Japanese, not in English."
        }
        let files = fileSummary(diff)
        let filesSection = files.isEmpty
            ? ""
            : "Changed files (for context only; do not name them in the message):\n" + files + "\n\n"
        return """
        Summarize this staged diff as a commit message. Do not repeat the diff.
        \(languageLine)

        \(filesSection)\(excerpt)
        """
    }

    /// 差分から、変更ファイルと追加・削除行数の一覧を作る。モデルが変更の全体像をつかむ手がかりにする。
    static func fileSummary(_ diff: String, limit: Int = 20) -> String {
        var entries: [(path: String, added: Int, removed: Int)] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let path = line.components(separatedBy: " b/").last ?? String(line)
                entries.append((path, 0, 0))
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            } else if line.hasPrefix("+"), !entries.isEmpty {
                entries[entries.count - 1].added += 1
            } else if line.hasPrefix("-"), !entries.isEmpty {
                entries[entries.count - 1].removed += 1
            }
        }
        var lines = entries.prefix(limit).map { "- \($0.path) (+\($0.added) -\($0.removed))" }
        if entries.count > limit {
            lines.append("- and \(entries.count - limit) more files")
        }
        return lines.joined(separator: "\n")
    }

    /// 対象が変更ファイルの名前（拡張子なし）を含んでいれば、その名前を返す。
    /// モデルが機能ではなくファイル名を対象にしたときの検出に使う。
    static func fileNameMentioned(in target: String, diff: String) -> String? {
        let lowered = target.lowercased()
        let stems = diff.split(separator: "\n")
            .filter { $0.hasPrefix("diff --git ") }
            .compactMap { line -> String? in
                guard let path = line.components(separatedBy: " b/").last else { return nil }
                let name = (path as NSString).lastPathComponent
                return (name as NSString).deletingPathExtension
            }
        return stems.first { $0.count >= 4 && lowered.contains($0.lowercased()) }
    }

    /// 動作と対象から、言語ごとのコミットメッセージらしい件名を組み立てる。
    /// 日本語は「〜を追加」のような体言止め、英語は「Add 〜」のような命令形にする。
    static func subject(action: CommitAction, target: String, language: CommitMessageLanguage) -> String? {
        let target = normalizedTarget(target, language: language)
        guard !target.isEmpty else { return nil }
        switch language {
        case .english:
            return action.englishVerb + " " + target
        case .japanese:
            return target + "を" + action.japaneseNoun
        }
    }

    /// 件名だけをメッセージにする。差分そのものは捨てる。
    static func message(subject: String, diff: String) -> String? {
        usableText(subject, diff: diff)
    }

    /// モデルが対象に動詞や句点を付けてしまったときに取り除く。
    private static func normalizedTarget(_ raw: String, language: CommitMessageLanguage) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingWrappingQuotes(text)
        let trailingMarks: Set<Character> = ["。", ".", "、", ",", "！", "!"]
        while let last = text.last, trailingMarks.contains(last) {
            text.removeLast()
        }
        switch language {
        case .english:
            let lowered = text.lowercased()
            for action in CommitAction.allCases {
                let verb = action.englishVerb.lowercased() + " "
                if lowered.hasPrefix(verb) {
                    text = String(text.dropFirst(verb.count))
                    break
                }
            }
            if let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true {
                text = first.lowercased() + text.dropFirst()
            }
        case .japanese:
            let verbEndings = ["しました", "します", "した", "する"]
            for ending in verbEndings where text.hasSuffix(ending) {
                text = String(text.dropLast(ending.count))
                break
            }
            for action in CommitAction.allCases where text.hasSuffix(action.japaneseNoun) {
                text = String(text.dropLast(action.japaneseNoun.count))
                break
            }
            while let last = text.last, ["を", "が", "は", "に", "の"].contains(last) {
                text.removeLast()
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("diff --git") || trimmed.hasPrefix("@@") || trimmed.contains("\n@@") {
            return true
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let patchCount = lines.reduce(into: 0) { count, line in
            let raw = line.drop(while: { $0 == " " || $0 == "\t" })
            if raw.hasPrefix("@@") || raw.hasPrefix("diff ") || raw.hasPrefix("index ")
                || raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("+") || raw.hasPrefix("-") {
                count += 1
            }
        }
        if patchCount >= 2 { return true }
        return lines.count == 1 && patchCount == 1
    }

    static func diffExcerpt(_ diff: String, limit: Int = characterLimit) -> String {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        let partial: Substring
        if let newline = head.lastIndex(of: "\n"), newline != head.startIndex {
            partial = head[..<newline]
        } else {
            partial = head
        }
        return partial + "\n\n" + omittedNote
    }

    /// モデルが説明や囲みを付けたとき、メッセージ本文だけを残す。
    static func cleanedMessage(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = strippingFence(text)
        text = strippingLabel(text)
        text = strippingWrappingQuotes(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > 2_000 {
            let end = text.index(text.startIndex, offsetBy: 2_000)
            text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func usableText(_ raw: String, diff: String) -> String? {
        guard let text = cleanedMessage(raw), !looksLikeDiff(text), !copiesDiff(text, diff: diff) else { return nil }
        return text
    }

    /// 本文の行の多くが差分の行そのものなら、コピーとみなす。
    private static func copiesDiff(_ message: String, diff: String) -> Bool {
        let messageLines = message.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard messageLines.count >= 3 else { return false }
        let diffLines = Set(diff.split(separator: "\n").map { line -> String in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("+") || text.hasPrefix("-") {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespaces)
            }
            return text
        })
        let hits = messageLines.filter { diffLines.contains($0) }.count
        return hits * 2 >= messageLines.count
    }

    private static func strippingFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingLabel(_ text: String) -> String {
        let label = "commit message:"
        guard text.lowercased().hasPrefix(label) else { return text }
        return String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("「", "」")]
        for (open, close) in pairs {
            guard text.count >= 2, text.first == open, text.last == close else { continue }
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

nonisolated enum CommitMessageSuggester {
    static var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    static func suggest(stagedDiff: String) async -> String? {
        let language = AppSettings.commitMessageLanguage
        guard let prompt = CommitMessagePrompt.prompt(for: stagedDiff, language: language) else {
            suggestionLog.error("prompt is nil (diff length: \(stagedDiff.count))")
            return nil
        }
        guard #available(macOS 26, *) else { return nil }
        return await AppleIntelligenceCommitMessage.suggest(
            prompt: prompt,
            instructions: CommitMessagePrompt.instructions(for: language),
            diff: stagedDiff,
            language: language
        )
    }
}

/// 件名の動作。モデルに選ばせることで、件名をコミットメッセージらしい形にそろえる。
nonisolated enum CommitAction: String, CaseIterable, Sendable {
    case add, fix, remove, update, refactor, rename, move, improve

    var englishVerb: String {
        switch self {
        case .add: "Add"
        case .fix: "Fix"
        case .remove: "Remove"
        case .update: "Update"
        case .refactor: "Refactor"
        case .rename: "Rename"
        case .move: "Move"
        case .improve: "Improve"
        }
    }

    var japaneseNoun: String {
        switch self {
        case .add: "追加"
        case .fix: "修正"
        case .remove: "削除"
        case .update: "変更"
        case .refactor: "リファクタリング"
        case .rename: "リネーム"
        case .move: "移動"
        case .improve: "改善"
        }
    }
}

@available(macOS 26, *)
@Generable
nonisolated private enum GeneratedCommitAction {
    case add, fix, remove, update, refactor, rename, move, improve

    var action: CommitAction {
        switch self {
        case .add: .add
        case .fix: .fix
        case .remove: .remove
        case .update: .update
        case .refactor: .refactor
        case .rename: .rename
        case .move: .move
        case .improve: .improve
        }
    }
}

@available(macOS 26, *)
@Generable
nonisolated private struct EnglishCommitMessage {
    @Guide(description: "The main kind of change: add new things, fix a bug, remove things, update behavior, refactor code without changing behavior, rename, move, or improve.")
    var action: GeneratedCommitAction

    @Guide(description: "Short English noun phrase describing the feature or behavior the action was applied to, without a verb or a file name, within 60 characters.")
    var target: String
}

@available(macOS 26, *)
@Generable
nonisolated private struct JapaneseCommitMessage {
    @Guide(description: "The main kind of change: add new things, fix a bug, remove things, update behavior, refactor code without changing behavior, rename, move, or improve.")
    var action: GeneratedCommitAction

    @Guide(description: "Short Japanese noun phrase describing the feature or behavior the action was applied to, without a verb, a file name, or a trailing period, within 30 characters.")
    var target: String
}

@available(macOS 26, *)
private nonisolated enum AppleIntelligenceCommitMessage {
    static func suggest(
        prompt: String,
        instructions: String,
        diff: String,
        language: CommitMessageLanguage
    ) async -> String? {
        let job = Task.detached(priority: .userInitiated) { () -> String? in
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                suggestionLog.error("model unavailable: \(String(describing: model.availability), privacy: .public)")
                return nil
            }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
            func generate(_ prompt: String) async throws -> (action: CommitAction, target: String) {
                switch language {
                case .english:
                    let content = try await session.respond(to: prompt, generating: EnglishCommitMessage.self, options: options).content
                    return (content.action.action, content.target)
                case .japanese:
                    let content = try await session.respond(to: prompt, generating: JapaneseCommitMessage.self, options: options).content
                    return (content.action.action, content.target)
                }
            }
            do {
                var (action, target) = try await generate(prompt)
                // ファイル名を対象にしたときは、機能を言葉で説明するよう1回だけ頼み直す。
                if let fileName = CommitMessagePrompt.fileNameMentioned(in: target, diff: diff) {
                    do {
                        (action, target) = try await generate("""
                            Do not use the file name "\(fileName)" as the target. \
                            Describe the feature or behavior that changed in plain words, and write the message again.
                            """)
                    } catch {
                        suggestionLog.error("retry failed: \(String(describing: error), privacy: .public)")
                    }
                }
                guard let subject = CommitMessagePrompt.subject(action: action, target: target, language: language) else {
                    suggestionLog.error("subject is nil (target became empty after normalization): \(target, privacy: .private)")
                    return nil
                }
                guard let message = CommitMessagePrompt.message(subject: subject, diff: diff) else {
                    suggestionLog.error("message rejected (looks like diff or copies diff): \(subject, privacy: .private)")
                    return nil
                }
                return message
            } catch {
                suggestionLog.error("generation failed: \(String(describing: error), privacy: .public)")
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
