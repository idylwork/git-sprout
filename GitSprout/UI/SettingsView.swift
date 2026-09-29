//
//  SettingsView.swift
//  GitSprout
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.reopenLastRepositoryKey) private var reopenLastRepository = true
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.Appearance.system.rawValue
    @AppStorage(AppSettings.showTerminalButtonKey) private var showTerminalButton = true
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = 13.0
    @AppStorage(AppSettings.stashIncludeUntrackedKey) private var stashIncludeUntracked = true
    @AppStorage(AppSettings.wrapDiffLinesKey) private var wrapDiffLines = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Previous Repository on Launch", isOn: $reopenLastRepository)
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
            }
            Section("Diff") {
                Toggle("Wrap Lines", isOn: $wrapDiffLines)
            }
            Section("Terminal") {
                Toggle("Show Terminal Button", isOn: $showTerminalButton)
                Stepper(value: $terminalFontSize, in: 10...24, step: 1) {
                    HStack {
                        Text("Font Size")
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int(terminalFontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Section("Stash") {
                Toggle("Include Untracked Files", isOn: $stashIncludeUntracked)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(20)
    }
}
