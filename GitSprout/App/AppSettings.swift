//
//  AppSettings.swift
//  GitSprout
//

import SwiftUI

enum AppSettings {
    static let showTerminalButtonKey = "showTerminalButton"
    static let terminalFontSizeKey = "terminalFontSize"
    static let stashIncludeUntrackedKey = "stashIncludeUntracked"
    static let appearanceKey = "appearance"
    static let reopenLastRepositoryKey = "reopenLastRepository"
    static let ignoreWhitespaceKey = "ignoreWhitespace"
    static let wrapDiffLinesKey = "wrapDiffLines"

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

    static func register() {
        UserDefaults.standard.register(defaults: [
            showTerminalButtonKey: true,
            terminalFontSizeKey: 13.0,
            stashIncludeUntrackedKey: true,
            appearanceKey: Appearance.system.rawValue,
            reopenLastRepositoryKey: true,
            ignoreWhitespaceKey: false,
            wrapDiffLinesKey: false,
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
}
