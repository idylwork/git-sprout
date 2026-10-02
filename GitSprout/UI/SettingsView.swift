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
    @AppStorage(AppSettings.listEachUntrackedFileKey) private var listEachUntrackedFile = true
    @AppStorage(AppSettings.commitMessageLanguageKey) private var commitMessageLanguage = AppSettings.defaultCommitMessageLanguage.rawValue
    @AppStorage(AppSettings.branchOrderKey) private var branchOrder = BranchOrder.lastCommit.rawValue

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Previous Repository on Launch", isOn: $reopenLastRepository)
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                Toggle("Wrap Lines", isOn: $wrapDiffLines)
                Picker("Branch Order", selection: $branchOrder) {
                    ForEach(BranchOrder.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
            }
            Section("Commit") {
                if CommitMessageSuggester.isAvailable || DiffReviewer.isAvailable {
                    Picker("Suggestion Language", selection: $commitMessageLanguage) {
                        ForEach(CommitMessageLanguage.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                }
                Toggle("List Each File in Untracked Folders", isOn: $listEachUntrackedFile)
            }
            Section("Stash") {
                Toggle("Include Untracked Files", isOn: $stashIncludeUntracked)
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(20)
    }
}
