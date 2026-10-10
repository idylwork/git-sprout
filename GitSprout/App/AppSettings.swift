import SwiftUI

enum AppSettings {
    static let showTerminalButtonKey = "showTerminalButton"
    static let terminalFontSizeKey = "terminalFontSize"
    static let stashIncludeUntrackedKey = "stashIncludeUntracked"
    static let appearanceKey = "appearance"
    static let reopenLastRepositoryKey = "reopenLastRepository"
    static let ignoreWhitespaceKey = "ignoreWhitespace"
    static let wrapDiffLinesKey = "wrapDiffLines"
    static let listEachUntrackedFileKey = "listEachUntrackedFile"
    static let commitMessageLanguageKey = "commitMessageLanguage"
    static let branchOrderKey = "branchOrder"

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: String(localized: "System")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    nonisolated static var defaultCommitMessageLanguage: CommitMessageLanguage {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("ja") ? .japanese : .english
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            showTerminalButtonKey: true,
            terminalFontSizeKey: 13.0,
            stashIncludeUntrackedKey: true,
            appearanceKey: Appearance.system.rawValue,
            reopenLastRepositoryKey: true,
            ignoreWhitespaceKey: false,
            wrapDiffLinesKey: false,
            listEachUntrackedFileKey: true,
            commitMessageLanguageKey: defaultCommitMessageLanguage.rawValue,
            branchOrderKey: BranchOrder.lastCommit.rawValue,
        ])
    }

    static var showTerminalButton: Bool {
        UserDefaults.standard.bool(forKey: showTerminalButtonKey)
    }

    static var terminalFontSize: Double {
        let value = UserDefaults.standard.double(forKey: terminalFontSizeKey)
        guard value > 0 else { return 13 }
        return min(24, max(10, value))
    }

    static var stashIncludeUntracked: Bool {
        UserDefaults.standard.bool(forKey: stashIncludeUntrackedKey)
    }

    static var appearance: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    static var reopenLastRepository: Bool {
        UserDefaults.standard.bool(forKey: reopenLastRepositoryKey)
    }

    static var ignoreWhitespace: Bool {
        UserDefaults.standard.bool(forKey: ignoreWhitespaceKey)
    }

    static var wrapDiffLines: Bool {
        UserDefaults.standard.bool(forKey: wrapDiffLinesKey)
    }

    /// 未追跡フォルダの中をファイルごとに出す。切るとフォルダ1件にまとめる。
    static var listEachUntrackedFile: Bool {
        UserDefaults.standard.bool(forKey: listEachUntrackedFileKey)
    }

    nonisolated static var commitMessageLanguage: CommitMessageLanguage {
        CommitMessageLanguage(rawValue: UserDefaults.standard.string(forKey: commitMessageLanguageKey) ?? "")
            ?? defaultCommitMessageLanguage
    }
}

/// サイドバーとリモートブランチのシートで使う並び順。
nonisolated enum BranchOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case lastCommit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .lastCommit: String(localized: "Last Commit Date")
        }
    }

    func sorted(_ branches: [Branch]) -> [Branch] {
        switch self {
        case .name:
            branches.sorted { $0.name < $1.name }
        case .lastCommit:
            branches.sorted { lhs, rhs in
                switch (lhs.committedAt, rhs.committedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                default:
                    return lhs.name < rhs.name
                }
            }
        }
    }
}

nonisolated enum CommitMessageLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case japanese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        }
    }
}
