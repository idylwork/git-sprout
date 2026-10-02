//
//  CommitMessageSuggestion.swift
//  GitSprout
//

import Foundation
import FoundationModels

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
            Write the subject and the body entirely in English.
            Use an imperative subject of at most 72 characters that names what changed and what you did to it.
            """
        case .japanese:
            languageLine = """
            Write the subject and the body entirely in Japanese. Do not write them in English.
            Write a subject of at most 72 characters that names what changed, then what was done to it, and ends with a past-tense verb.
            Do not end the subject with a noun.
            """
        }
        return """
        You summarize a staged git diff as one commit message.
        The diff is evidence. Never copy it, quote it, continue it, or include code from it.
        Never include a line that starts with diff, index, @@, +, or -.
        \(languageLine)
        The body is optional. Leave it empty unless it adds a fact the subject does not state. Never restate the subject.
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
        return """
        Summarize this staged diff as a commit message. Do not repeat the diff.
        \(languageLine)

        \(excerpt)
        """
    }

    /// 件名と本文を1つのメッセージにする。差分そのものは捨てる。
    static func message(subject: String, body: String, diff: String) -> String? {
        guard let subject = usableText(subject, diff: diff) else { return nil }
        guard let body = usableText(body, diff: diff), !restates(body, subject: subject) else { return subject }
        return subject + "\n\n" + body
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

    /// 本文の文字のほとんどが件名にもあるときは、件名の言い換えとみなす。
    private static func restates(_ body: String, subject: String) -> Bool {
        let bodyChars = contentCharacters(body)
        let subjectChars = contentCharacters(subject)
        guard bodyChars.count >= 4, subjectChars.count >= 4 else { return false }
        let overlap = bodyChars.filter { subjectChars.contains($0) }.count
        return overlap * 5 >= bodyChars.count * 4
    }

    private static func contentCharacters(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
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
        guard let prompt = CommitMessagePrompt.prompt(for: stagedDiff, language: language) else { return nil }
        guard #available(macOS 26, *) else { return nil }
        return await AppleIntelligenceCommitMessage.suggest(
            prompt: prompt,
            instructions: CommitMessagePrompt.instructions(for: language),
            diff: stagedDiff,
            language: language
        )
    }
}

@available(macOS 26, *)
@Generable
nonisolated private struct EnglishCommitMessage {
    @Guide(description: "English subject naming what changed and the action taken, within 72 characters.")
    var subject: String

    @Guide(description: "Optional English detail the subject does not already state.")
    var body: String?
}

@available(macOS 26, *)
@Generable
nonisolated private struct JapaneseCommitMessage {
    @Guide(description: "Japanese subject naming what changed and the action taken, ending with a past-tense verb, within 72 characters.")
    var subject: String

    @Guide(description: "Optional Japanese detail the subject does not already state.")
    var body: String?
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
            guard model.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
            do {
                let subject: String
                let body: String
                switch language {
                case .english:
                    let response = try await session.respond(to: prompt, generating: EnglishCommitMessage.self, options: options)
                    subject = response.content.subject
                    body = response.content.body ?? ""
                case .japanese:
                    let response = try await session.respond(to: prompt, generating: JapaneseCommitMessage.self, options: options)
                    subject = response.content.subject
                    body = response.content.body ?? ""
                }
                return CommitMessagePrompt.message(subject: subject, body: body, diff: diff)
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
