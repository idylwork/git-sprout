//
//  GitParsers.swift
//  GitSprout
//

import Foundation

nonisolated enum GitStatusParser {
    static func parse(_ data: Data) -> [FileChange] {
        let parts = splitNUL(data)
        var index = 0
        var files: [FileChange] = []
        while index < parts.count {
            let record = parts[index]
            index += 1
            if record.isEmpty { continue }
            if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                if !path.isEmpty {
                    files.append(FileChange(path: path, originalPath: nil, staged: .none, unstaged: .untracked))
                }
                continue
            }
            if record.hasPrefix("! ") { continue }
            guard let kind = record.first else { continue }
            if kind == "1" {
                guard let split = splitHead(record, 8), split.fields.count >= 2 else { continue }
                files.append(change(path: split.remainder, original: nil, xy: split.fields[1]))
            } else if kind == "2" {
                guard let split = splitHead(record, 9), index < parts.count else { continue }
                let original = parts[index]
                index += 1
                files.append(change(path: split.remainder, original: original, xy: split.fields[1]))
            } else if kind == "u" {
                guard let split = splitHead(record, 10) else { continue }
                files.append(FileChange(path: split.remainder, originalPath: nil, staged: .unmerged, unstaged: .unmerged))
            }
        }
        return files
    }

    private static func change(path: String, original: String?, xy: String) -> FileChange {
        let staged = xy.first.map(ChangeKind.init(code:)) ?? .none
        let unstaged = xy.dropFirst().first.map(ChangeKind.init(code:)) ?? .none
        return FileChange(path: path, originalPath: original, staged: staged, unstaged: unstaged)
    }
}

nonisolated enum GitLogParser {
    static func parse(_ data: Data) -> [CommitRecord] {
        let text = String(decoding: data, as: UTF8.self)
        let records = text.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var commits: [CommitRecord] = []
        commits.reserveCapacity(records.count)
        for record in records {
            // `format:` はレコード区切りのあとに改行を足す
            let cleaned = record.drop(while: \.isNewline)
            let fields = cleaned.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, !fields[0].isEmpty else { continue }
            let parents = fields[1].split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let subject = fields[6]
            let body = fields.count > 7 ? normalizeBody(fields[7...].joined(separator: "\u{1f}")) : ""
            commits.append(CommitRecord(
                oid: fields[0],
                parents: parents,
                authorName: fields[2],
                authorEmail: fields[3],
                authoredAt: formatter.date(from: fields[4]) ?? .distantPast,
                decoration: displayDecoration(fields[5]),
                subject: subject,
                body: body
            ))
        }
        return commits
    }

    /// `%b` は本文の末尾に改行を付ける。先頭の空行と末尾の改行だけ除く。
    private static func normalizeBody(_ raw: String) -> String {
        var text = Substring(raw)
        while text.first?.isNewline == true {
            text.removeFirst()
        }
        while text.last?.isNewline == true {
            text.removeLast()
        }
        return String(text)
    }
}

nonisolated func displayDecoration(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count >= 2, text.hasPrefix("("), text.hasSuffix(")") {
        text = String(text.dropFirst().dropLast())
    }
    let pieces = text.split(separator: ",").compactMap { rawPiece -> String? in
        var item = rawPiece.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isEmpty { return nil }
        if let arrow = item.range(of: " -> ") {
            item = String(item[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if item.hasPrefix("tag: ") {
            item.removeFirst(5)
        }
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where item.hasPrefix(prefix) {
            item.removeFirst(prefix.count)
        }
        return item.isEmpty ? nil : item
    }
    return pieces.joined(separator: ", ")
}

nonisolated enum GitBranchParser {
    static func parse(_ data: Data) -> [Branch] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return Branch(
                name: fields[0],
                oid: fields[1],
                isCurrent: fields[2].contains("*"),
                upstream: fields.count > 3 ? nonempty(fields[3]) : nil,
                remoteName: fields.count > 4 ? nonempty(fields[4]) : nil,
                sync: fields.count > 5 ? sync(from: fields[5]) : .unknown,
                subject: fields.count > 7 ? fields[7...].joined(separator: "\t") : "",
                committedAt: fields.count > 6 ? date(from: fields[6]) : nil
            )
        }
    }

    /// `%(upstream:track)` の `[ahead N]`、`[behind M]`、`[ahead N, behind M]`、`=` を読む。
    static func sync(from track: String) -> BranchSync {
        let ahead = count(track, label: "ahead ")
        let behind = count(track, label: "behind ")
        if ahead > 0, behind > 0 { return .diverged(ahead: ahead, behind: behind) }
        if ahead > 0 { return .ahead(ahead) }
        if behind > 0 { return .behind(behind) }
        if track.trimmingCharacters(in: .whitespacesAndNewlines) == "=" { return .upToDate }
        return .unknown
    }

    private static func count(_ track: String, label: String) -> Int {
        guard let range = track.range(of: label) else { return 0 }
        var value = 0
        var sawDigit = false
        for character in track[range.upperBound...] {
            guard character.isNumber, let digit = character.wholeNumberValue else { break }
            sawDigit = true
            value = value * 10 + digit
        }
        return sawDigit ? value : 0
    }

    private static func nonempty(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(from field: String) -> Date? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = TimeInterval(trimmed), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

nonisolated struct RemoteHead: Sendable, Equatable {
    var remote: String
    var name: String
    var oid: String
    var subject: String = ""
    var committedAt: Date? = nil
}

nonisolated enum GitRemoteHeadParser {
    static func parse(_ data: Data) -> [RemoteHead] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let slash = fields[0].firstIndex(of: "/") else { return nil }
            let remote = String(fields[0][..<slash])
            let name = String(fields[0][fields[0].index(after: slash)...])
            guard !remote.isEmpty, !name.isEmpty, name != "HEAD" else { return nil }
            return RemoteHead(
                remote: remote,
                name: name,
                oid: fields[1],
                subject: fields.count > 3 ? fields[3...].joined(separator: "\t") : "",
                committedAt: fields.count > 2 ? GitBranchParser.date(from: fields[2]) : nil
            )
        }
    }

    /// 同名の追跡先。origin を優先し、origin が無く候補が複数なら決めない。
    static func match(name: String, heads: [RemoteHead]) -> RemoteHead? {
        let matches = heads.filter { $0.name == name }
        if let origin = matches.first(where: { $0.remote == "origin" }) { return origin }
        return matches.count == 1 ? matches[0] : nil
    }
}

nonisolated enum GitStashParser {
    static func parse(_ data: Data) -> [StashEntry] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let cleaned = record.drop(while: \.isNewline)
            let fields = cleaned.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            let subject = fields[2...].joined(separator: "\u{1f}")
            return StashEntry(ref: fields[0], oid: fields[1], subject: subject)
        }
    }
}

nonisolated enum GitPathStatusParser {
    static func parse(_ data: Data) -> [PathStatus] {
        let parts = splitNUL(data)
        var index = 0
        var files: [PathStatus] = []
        while index < parts.count {
            let code = parts[index]
            index += 1
            if code.isEmpty { continue }
            if code.hasPrefix("R") || code.hasPrefix("C") {
                guard index + 1 < parts.count else { break }
                let old = parts[index]
                index += 1
                let new = parts[index]
                index += 1
                files.append(PathStatus(code: String(code.prefix(1)), path: new, originalPath: old))
            } else {
                guard index < parts.count else { break }
                let path = parts[index]
                index += 1
                files.append(PathStatus(code: String(code.prefix(1)), path: path, originalPath: nil))
            }
        }
        return files
    }
}

nonisolated enum GitGrepParser {
    static func parseLine(_ line: String) -> ContentHit? {
        var search = line.startIndex
        while search < line.endIndex, let colon = line[search...].firstIndex(of: ":") {
            let after = line.index(after: colon)
            guard after < line.endIndex else { return nil }
            guard let second = line[after...].firstIndex(of: ":") else { return nil }
            let number = line[after..<second]
            if let lineNumber = Int(number) {
                let textStart = line.index(after: second)
                return ContentHit(path: String(line[..<colon]), line: lineNumber, text: String(line[textStart...]))
            }
            search = after
        }
        return nil
    }
}

nonisolated enum GitDiffParser {
    static func parse(_ data: Data) -> DiffDocument {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("Binary files ") || text.contains("GIT binary patch") {
            let lines = logicalLines(text)
            let rename = renamePair(lines)
            return DiffDocument(
                binary: true,
                truncated: false,
                header: "",
                hunks: [],
                renameFrom: rename?.from,
                renameTo: rename?.to
            )
        }
        let lines = logicalLines(text)
        let rename = renamePair(lines)
        guard let hunkStart = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
            return DiffDocument(
                binary: false,
                truncated: false,
                header: lines.joined(separator: "\n"),
                hunks: [],
                renameFrom: rename?.from,
                renameTo: rename?.to
            )
        }
        let header = lines[..<hunkStart].joined(separator: "\n") + "\n"
        var hunks: [DiffHunk] = []
        var index = hunkStart
        var lineID = 0
        while index < lines.count {
            let marker = lines[index]
            guard marker.hasPrefix("@@") else { break }
            let meta = parseHunkHeader(marker)
            index += 1
            var body: [String] = []
            var diffLines: [DiffLine] = []
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("@@") || line.hasPrefix("diff --git ") { break }
                diffLines.append(DiffLine(id: lineID, kind: kind(of: line), text: displayText(of: line)))
                lineID += 1
                body.append(line)
                index += 1
            }
            let raw = ([marker] + body).joined(separator: "\n") + "\n"
            hunks.append(DiffHunk(
                index: hunks.count,
                oldStart: meta.oldStart,
                oldCount: meta.oldCount,
                newStart: meta.newStart,
                newCount: meta.newCount,
                heading: meta.heading,
                lines: diffLines,
                patch: header + raw
            ))
        }
        return DiffDocument(
            binary: false,
            truncated: false,
            header: header,
            hunks: hunks,
            renameFrom: rename?.from,
            renameTo: rename?.to
        )
    }

    private static func renamePair(_ lines: [String]) -> (from: String, to: String)? {
        var from: String?
        var to: String?
        for line in lines {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("rename from ") {
                from = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                to = String(line.dropFirst("rename to ".count))
            }
        }
        guard let from, let to else { return nil }
        return (from, to)
    }

    private static func kind(of line: String) -> DiffLine.Kind {
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .deletion }
        if line.hasPrefix("\\") { return .meta }
        return .context
    }

    private static func displayText(of line: String) -> String {
        if line.hasPrefix("\\") { return line }
        if line.isEmpty { return "" }
        return String(line.dropFirst())
    }

    private static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let newline = text[cursor...].firstIndex(of: "\n") {
                lines.append(String(text[cursor..<newline]))
                cursor = text.index(after: newline)
            } else {
                lines.append(String(text[cursor...]))
                break
            }
        }
        return lines
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String) {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return (0, 0, 0, 0, "")
        }
        func value(_ index: Int, default defaultValue: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return defaultValue }
            return Int(line[swiftRange]) ?? defaultValue
        }
        let headingRange = match.range(at: 5)
        let heading: String
        if headingRange.location != NSNotFound, let swiftRange = Range(headingRange, in: line) {
            heading = line[swiftRange].trimmingCharacters(in: .whitespaces)
        } else {
            heading = ""
        }
        return (value(1, default: 0), value(2, default: 1), value(3, default: 0), value(4, default: 1), heading)
    }
}

/// 選択した追加・削除行だけを含む `git apply` 用パッチを作る。
nonisolated enum DiffLinePatch {
    static func make(document: DiffDocument, selectedIDs: Set<Int>) -> String? {
        let bodies = document.hunks.compactMap { rewrite($0, selectedIDs: selectedIDs) }
        guard !bodies.isEmpty else { return nil }
        return document.header + bodies.joined()
    }

    private static func rewrite(_ hunk: DiffHunk, selectedIDs: Set<Int>) -> String? {
        var emitted: [String] = []
        var oldCount = 0
        var newCount = 0
        var keptChange = false
        var index = 0
        while index < hunk.lines.count {
            let line = hunk.lines[index]
            if line.kind == .meta {
                index += 1
                continue
            }
            let meta = index + 1 < hunk.lines.count && hunk.lines[index + 1].kind == .meta ? hunk.lines[index + 1] : nil
            let kind: DiffLine.Kind
            switch line.kind {
            case .context:
                kind = .context
            case .addition, .deletion:
                if selectedIDs.contains(line.id) {
                    kind = line.kind
                    keptChange = true
                } else if line.kind == .deletion {
                    kind = .context
                } else {
                    index += 1
                    continue
                }
            case .meta:
                index += 1
                continue
            }
            emitted.append(raw(line, kind: kind))
            switch kind {
            case .context:
                oldCount += 1
                newCount += 1
            case .deletion:
                oldCount += 1
            case .addition:
                newCount += 1
            case .meta:
                break
            }
            if let meta {
                emitted.append(meta.text)
            }
            index += 1
        }
        guard keptChange else { return nil }
        let heading = hunk.heading.isEmpty ? "" : " \(hunk.heading)"
        let marker = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@\(heading)\n"
        return marker + emitted.joined(separator: "\n") + "\n"
    }

    private static func raw(_ line: DiffLine, kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+" + line.text
        case .deletion: return "-" + line.text
        case .context: return " " + line.text
        case .meta: return line.text
        }
    }
}

/// `git ls-files -s -z` から、ステージ 0 の通常ファイルを取る。
nonisolated enum IndexStageParser {
    static func regularBlob(_ data: Data) -> (mode: String, hash: String)? {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let tab = data[cursor...].firstIndex(of: 0x09),
                  let nul = data[tab...].firstIndex(of: 0x00) else { return nil }
            let header = String(decoding: data[cursor..<tab], as: UTF8.self)
            let fields = header.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, fields[2] == "0" {
                let mode = String(fields[0])
                guard mode == "100644" || mode == "100755" else { return nil }
                return (mode, String(fields[1]))
            }
            let next = data.index(after: nul)
            if next <= cursor { return nil }
            cursor = next
        }
        return nil
    }
}

nonisolated func splitNUL(_ data: Data) -> [String] {
    var parts: [String] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0 {
        parts.append(String(decoding: data[start..<index], as: UTF8.self))
        start = data.index(after: index)
    }
    return parts
}

private nonisolated func splitHead(_ record: String, _ headCount: Int) -> (fields: [String], remainder: String)? {
    var fields: [String] = []
    fields.reserveCapacity(headCount)
    var cursor = record.startIndex
    while fields.count < headCount {
        guard let space = record[cursor...].firstIndex(of: " ") else { return nil }
        fields.append(String(record[cursor..<space]))
        cursor = record.index(after: space)
    }
    return (fields, String(record[cursor...]))
}
