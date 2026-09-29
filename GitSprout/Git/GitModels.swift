//
//  GitModels.swift
//  GitSprout
//

import Foundation

nonisolated enum GitLimits {
    /// 履歴とファイル履歴の1ページ。
    static let pageSize = 200
    static let diffByteLimit = 1_000_000
    static let fileByteLimit = 1_000_000
    /// 画像の差分として読む上限。
    static let imageByteLimit = 20_000_000
    static let listByteLimit = 2_000_000
    static let searchLimit = 200
}

nonisolated struct GitFailure: Error, LocalizedError, Sendable, Equatable {
    var message: String
    var errorDescription: String? { message }
}

nonisolated struct GitCancelled: Error, Sendable {}

nonisolated struct GitOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String
    var truncated: Bool
}

nonisolated struct HeadState: Sendable, Equatable {
    var name: String
    var oid: String
    var detached: Bool
    var unborn: Bool

    static let unknown = HeadState(name: "…", oid: "", detached: false, unborn: false)

    var title: String {
        if unborn { return String(localized: "\(name) (no commits)") }
        if detached {
            let short = oid.isEmpty ? "HEAD" : String(oid.prefix(7))
            return String(localized: "Detached \(short)")
        }
        return name
    }
}

nonisolated enum ChangeKind: String, Sendable, Equatable {
    case none = "."
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typechange = "T"
    case unmerged = "U"
    case untracked = "?"
    case ignored = "!"

    init(code: Character) {
        self = ChangeKind(rawValue: String(code)) ?? .modified
    }

    var label: String { rawValue == "." ? "" : rawValue }
}

nonisolated struct FileChange: Identifiable, Sendable, Equatable {
    var path: String
    var originalPath: String?
    var staged: ChangeKind
    var unstaged: ChangeKind

    var id: String { path }

    var hasStaged: Bool {
        switch staged {
        case .none, .untracked, .ignored:
            return false
        default:
            return true
        }
    }

    var hasUnstaged: Bool {
        switch unstaged {
        case .none, .ignored:
            return false
        default:
            return true
        }
    }

    var displayPath: String {
        if let originalPath, originalPath != path {
            return "\(originalPath) → \(path)"
        }
        return path
    }
}

nonisolated struct StatusSnapshot: Sendable, Equatable {
    var files: [FileChange]
    var truncated: Bool
}

nonisolated struct CommitRecord: Identifiable, Sendable, Equatable {
    var oid: String
    var parents: [String]
    var authorName: String
    var authorEmail: String
    var authoredAt: Date
    var decoration: String
    var subject: String

    var id: String { oid }

    static let uncommittedOID = "UNCOMMITTED"

    init(
        oid: String,
        parents: [String],
        authorName: String = "",
        authorEmail: String = "",
        authoredAt: Date = .distantPast,
        decoration: String = "",
        subject: String = ""
    ) {
        self.oid = oid
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.decoration = decoration
        self.subject = subject
    }
}

nonisolated struct LogPage: Sendable, Equatable {
    var commits: [CommitRecord]
    var hasMore: Bool
}

nonisolated struct Branch: Identifiable, Sendable, Equatable {
    var name: String
    var oid: String
    var isCurrent: Bool
    /// `origin/main` のような上流。追跡先がなければ nil。
    var upstream: String? = nil
    /// 上流のリモート名。ローカルブランチを追跡しているときは nil。
    var remoteName: String? = nil
    var id: String { name }
}

/// 表示に使うリモート。ブラウザで開けないパスのときは `browserURL` が nil。
nonisolated struct RemoteLink: Sendable, Equatable {
    var name: String
    var browserURL: URL?
}

/// ローカルブランチと上流の差。amend などで両側に固有のコミットがあると `.diverged`。
nonisolated enum PushDivergence: Sendable, Equatable {
    case upToDate
    case fastForward
    case behind
    case diverged
}

nonisolated enum RemoteBrowserURL {
    /// リモートの取得 URL を、ブラウザで開けるページにする。ローカルパスは nil。
    static func page(from remoteURL: String) -> URL? {
        let raw = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../") || raw.hasPrefix("file://") {
            return nil
        }
        guard let web = httpsString(from: raw),
              var components = URLComponents(string: web),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.user = nil
        components.password = nil
        if components.port == 22 || components.port == 443 {
            components.port = nil
        }
        components.scheme = "https"
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty else { return nil }
        components.percentEncodedPath = path
        return components.url
    }

    private static func httpsString(from raw: String) -> String? {
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") {
            return raw
        }
        if raw.hasPrefix("ssh://") || raw.hasPrefix("git://") {
            guard let range = raw.range(of: "://") else { return nil }
            return "https://" + raw[range.upperBound...]
        }
        guard !raw.contains("://"),
              let at = raw.firstIndex(of: "@"),
              let colon = raw[raw.index(after: at)...].firstIndex(of: ":") else {
            return nil
        }
        let host = raw[raw.index(after: at)..<colon]
        let path = raw[raw.index(after: colon)...]
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return "https://\(host)/\(path)"
    }
}

nonisolated struct StashEntry: Identifiable, Sendable, Equatable {
    var ref: String
    var oid: String
    var subject: String
    var id: String { "\(ref) \(oid)" }
}

nonisolated struct PathStatus: Identifiable, Sendable, Equatable {
    var code: String
    var path: String
    var originalPath: String?
    var id: String { "\(code) \(originalPath ?? "") \(path)" }

    var displayPath: String {
        if let originalPath {
            return "\(originalPath) → \(path)"
        }
        return path
    }
}

nonisolated struct DiffLine: Identifiable, Sendable, Equatable {
    var id: Int
    var kind: Kind
    var text: String

    enum Kind: Sendable, Equatable {
        case context
        case addition
        case deletion
        case meta
    }

    var prefix: String {
        switch kind {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        case .meta: return ""
        }
    }
}

nonisolated struct DiffHunk: Identifiable, Sendable, Equatable {
    var index: Int
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var heading: String
    var lines: [DiffLine]
    /// `git apply` に渡せる、このハンクだけのパッチ。
    var patch: String

    var id: Int { index }
}

nonisolated enum ImagePayload: Sendable, Equatable {
    case absent
    case tooLarge
    case data(Data)
}

nonisolated enum ImagePaths {
    /// AppKit がそのまま描ける形式。PDF はページごとに開く。
    static func isImage(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    private static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "webp", "avif", "heic", "heif", "heics",
        "tif", "tiff", "bmp", "ico", "icns", "jp2", "j2k", "jpx", "jpf", "tga", "targa",
        "psd", "exr", "pbm", "pgm", "ppm", "pnm", "pdf",
    ]
}

nonisolated struct DiffDocument: Sendable, Equatable {
    var binary: Bool
    var truncated: Bool
    var header: String
    var hunks: [DiffHunk]
    var renameFrom: String?
    var renameTo: String?
    var beforeImage: ImagePayload = .absent
    var afterImage: ImagePayload = .absent

    static let empty = DiffDocument(binary: false, truncated: false, header: "", hunks: [], renameFrom: nil, renameTo: nil)
    static let tooLarge = DiffDocument(binary: false, truncated: true, header: "", hunks: [], renameFrom: nil, renameTo: nil)

    var isEmpty: Bool { !binary && !truncated && hunks.isEmpty && renameFrom == nil }

    var hasImageDiff: Bool { beforeImage != .absent || afterImage != .absent }
}

nonisolated struct FileBlob: Sendable, Equatable {
    var byteCount: Int
    var truncated: Bool
    var binary: Bool
    var text: String
    var image: Data? = nil
}

nonisolated struct ContentHit: Identifiable, Sendable, Equatable {
    var path: String
    var line: Int
    var text: String
    var id: String { "\(path):\(line):\(text)" }
}

nonisolated struct CappedList<Element: Sendable>: Sendable {
    var values: [Element]
    var capped: Bool
}

nonisolated enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case commits
    case branches
    case stashes
    case search

    var id: String { rawValue }

    static let pages: [SidebarSection] = [.commits, .stashes, .search]

    var title: String {
        switch self {
        case .commits: String(localized: "Commit")
        case .branches: String(localized: "Branches")
        case .stashes: String(localized: "Stashes")
        case .search: String(localized: "Search")
        }
    }

    var symbol: String {
        switch self {
        case .commits: return "point.3.connected.trianglepath.dotted"
        case .branches: return "arrow.triangle.branch"
        case .stashes: return "archivebox"
        case .search: return "magnifyingglass"
        }
    }
}

nonisolated enum SearchKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case message
    case path
    case content

    var id: String { rawValue }

    var title: String {
        switch self {
        case .message: String(localized: "Message")
        case .path: String(localized: "Path")
        case .content: String(localized: "File Content")
        }
    }
}

nonisolated enum FileBodyMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case content
    case parentDiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content: String(localized: "Content")
        case .parentDiff: String(localized: "Diff from Parent")
        }
    }
}

nonisolated struct FileSelection: Hashable, Sendable {
    var path: String
    var staged: Bool
    var commitOID: String?

    init(path: String, staged: Bool, commitOID: String? = nil) {
        self.path = path
        self.staged = staged
        self.commitOID = commitOID
    }
}
