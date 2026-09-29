//
//  WorkspaceView.swift
//  GitSprout
//

import Combine
import SwiftUI

struct WorkspaceView: View {
    @Bindable var session: WorkspaceSession
    var model: AppModel
    @AppStorage(AppSettings.showTerminalButtonKey) private var showTerminalButton = true
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = 13.0
    @AppStorage(AppSettings.ignoreWhitespaceKey) private var ignoreWhitespace = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var renamingBranch: String?
    @State private var renameOriginal = ""
    @State private var renameDraft = ""
    @State private var terminalFocus = 0
    @State private var sidebarWidth: CGFloat = 210
    @State private var historyHeight: CGFloat = 210
    @State private var stashHeight: CGFloat = 210
    @FocusState private var keyboardTarget: KeyboardTarget?

    var body: some View {
        PaneSplit(
            axis: .horizontal,
            primarySize: $sidebarWidth,
            minPrimary: 180,
            maxPrimary: 480,
            minSecondary: 660
        ) {
            sidebarColumn
        } secondary: {
            contentColumn
        }
        .environment(\.keyboardFocus, KeyboardFocus($keyboardTarget))
        .navigationTitle(session.displayName)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    RecentRepositoryMenu(
                        model: model,
                        currentPath: session.rootPath,
                        title: session.displayName
                    )
                    Text(session.head.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if session.isLoading || session.isMutating {
                ToolbarItem {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    guard let url = session.remoteLink?.browserURL else { return }
                    openURL(url)
                } label: {
                    Label("Open Remote", systemImage: "globe")
                        .labelStyle(.iconOnly)
                }
                .help("Open Remote")
                .disabled(session.remoteLink?.browserURL == nil)
                Menu {
                    Toggle("Hide Whitespace Changes", isOn: $ignoreWhitespace)
                    Divider()
                    Button("Settings…") {
                        openSettings()
                    }
                } label: {
                    Label("Options", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
            }
        }
        .onChange(of: ignoreWhitespace) { _, _ in
            Task { await session.reloadOpenDiffs() }
        }
        .task(id: session.rootPath) {
            await session.initialLoad()
            if NSApp.isActive {
                session.startWatching()
            }
        }
        .onDisappear {
            session.stopWatching()
        }
        .onChange(of: session.section) { _, _ in
            Task { await session.loadSectionIfNeeded() }
        }
        .onChange(of: session.terminalVisible) { _, isVisible in
            if isVisible {
                terminalFocus += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.startWatching()
            if !session.didActivateOnce {
                session.didActivateOnce = true
                return
            }
            Task { await session.refreshActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.stopWatching()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
        .confirmationDialog(
            session.pendingConfirm?.title ?? "",
            isPresented: Binding(
                get: { session.pendingConfirm != nil },
                set: { if !$0 { session.pendingConfirm = nil } }
            ),
            presenting: session.pendingConfirm
        ) { confirm in
            if confirm.isDestructive {
                Button(confirm.confirmTitle, role: .destructive) {
                    Task { await session.perform(confirm) }
                }
            } else {
                Button(confirm.confirmTitle) {
                    Task { await session.perform(confirm) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
        .sheet(
            isPresented: Binding(
                get: { session.fileHistoryPath != nil && !session.showsRangeDiff },
                set: { if !$0 { session.closeFileHistory() } }
            )
        ) {
            FileHistorySheet(session: session)
        }
        .alert(
            "Rename Branch",
            isPresented: Binding(
                get: { renamingBranch != nil },
                set: { if !$0 { renamingBranch = nil } }
            )
        ) {
            TextField("Branch Name", text: $renameDraft)
            Button("Rename") {
                let original = renameOriginal
                let draft = renameDraft
                Task { await session.renameBranch(original, to: draft) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a new name for \(renameOriginal).")
        }
    }

    private var sidebarColumn: some View {
        VSplitView {
            sidebar
                .frame(minHeight: 140)
            if session.terminalVisible {
                TerminalPanel(
                    directory: session.rootPath,
                    focusToken: terminalFocus,
                    fontSize: terminalFontSize
                )
                    .id(session.rootPath)
                    .frame(minHeight: 120, idealHeight: 200)
            }
        }
    }

    private var terminalToggle: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                session.terminalVisible.toggle()
            } label: {
                Label("Terminal", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if session.terminalVisible {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.22))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityAddTraits(session.terminalVisible ? .isSelected : [])
        }
        .frame(maxWidth: .infinity)
        .background(.windowBackground)
    }

    private var sidebar: some View {
        sectionList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showTerminalButton {
                    terminalToggle
                }
            }
    }

    private var sectionList: some View {
        List(selection: $session.section) {
            ForEach(SidebarSection.pages) { section in
                HStack {
                    Label(section.title, systemImage: section.symbol)
                    Spacer()
                    if section == .commits, session.changeCount > 0 {
                        Text("\(session.changeCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(section)
            }
            Section(isExpanded: $session.branchesExpanded) {
                if session.branchesLoading && session.branches.isEmpty {
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                } else if session.branches.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.branches) { branch in
                    branchRow(branch)
                }
            } header: {
                Label("Branches", systemImage: "arrow.triangle.branch")
            }
        }
        .listStyle(.sidebar)
        .keyboardTarget(.sidebar)
    }

    private func branchRow(_ branch: Branch) -> some View {
        HStack {
            Text(branch.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            if branch.isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { checkout(branch) })
        .simultaneousGesture(TapGesture(count: 1).onEnded { focus(branch) })
        .contextMenu {
            Button("Checkout") {
                checkout(branch)
            }
            .disabled(branch.isCurrent || session.isMutating)
            Divider()
            Button("Pull") {
                guard let upstream = branch.upstream, let remote = branch.remoteName else { return }
                session.pendingConfirm = .pull(
                    name: branch.name,
                    upstream: upstream,
                    remote: remote,
                    isCurrent: branch.isCurrent
                )
            }
            .disabled(branch.upstream == nil || branch.remoteName == nil || session.isMutating)
            Button("Push") {
                Task { await session.push(branch) }
            }
            .disabled(session.isMutating || (session.remoteLink == nil && branch.remoteName == nil))
            Button("Delete", role: .destructive) {
                session.pendingConfirm = .deleteBranch(branch.name)
            }
            .disabled(branch.isCurrent || session.isMutating)
            Button("Rename") {
                renameOriginal = branch.name
                renameDraft = branch.name
                renamingBranch = branch.name
            }
            .disabled(session.isMutating)
            Button("Rebase") {
                guard let upstream = branch.upstream else { return }
                session.pendingConfirm = .rebaseBranch(name: branch.name, upstream: upstream, remote: branch.remoteName)
            }
            .disabled(branch.upstream == nil || session.isMutating)
            Button("Force Match Remote", role: .destructive) {
                guard let upstream = branch.upstream, let remote = branch.remoteName else { return }
                session.pendingConfirm = .matchRemote(
                    name: branch.name,
                    upstream: upstream,
                    remote: remote,
                    isCurrent: branch.isCurrent
                )
            }
            .disabled(branch.upstream == nil || branch.remoteName == nil || session.isMutating)
        }
    }

    private func focus(_ branch: Branch) {
        guard !session.isMutating else { return }
        Task { await session.focusBranch(branch) }
    }

    private func checkout(_ branch: Branch) {
        guard !branch.isCurrent, !session.isMutating else { return }
        Task { await session.switchBranch(branch.name) }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if session.section == .commits {
            PaneSplit(
                axis: .vertical,
                primarySize: $historyHeight,
                minPrimary: 120,
                minSecondary: 180
            ) {
                HistoryView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                HistoryDetailView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if session.section == .stashes {
            PaneSplit(
                axis: .vertical,
                primarySize: $stashHeight,
                minPrimary: 120,
                minSecondary: 180
            ) {
                StashView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                StashDetailView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HSplitView {
                mainPane
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                detailPane
                    .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch session.section {
        case .commits:
            HistoryView(session: session)
        case .branches:
            ChangesView(session: session)
        case .stashes:
            StashView(session: session)
        case .search:
            SearchView(session: session)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch session.section {
        case .commits:
            HistoryDetailView(session: session)
        case .branches:
            ChangesDiffView(session: session)
        case .stashes:
            StashDetailView(session: session)
        case .search:
            SearchDetailView(session: session)
        }
    }
}

private struct RecentRepositoryMenu: View {
    var model: AppModel
    var currentPath: String
    var title: String

    var body: some View {
        Menu {
            if !model.recent.isEmpty {
                Section("Recent Repositories") {
                    ForEach(model.recent, id: \.self) { path in
                        Button {
                            Task { await model.open(path: path) }
                        } label: {
                            Label(
                                RepositoryPath.menuTitle(for: path, among: model.recent),
                                systemImage: path == currentPath ? "checkmark" : "folder"
                            )
                        }
                    }
                }
                Divider()
            }
            Button("Open Repository…") {
                model.openPanel()
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(currentPath)
    }
}
