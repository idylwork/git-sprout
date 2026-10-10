import AppKit
import Combine
import SwiftUI

struct WorkspaceView: View {
    @Bindable var session: WorkspaceSession
    var model: AppModel
    @AppStorage(AppSettings.showTerminalButtonKey) private var showTerminalButton = true
    @AppStorage(AppSettings.terminalFontSizeKey) private var terminalFontSize = 13.0
    @AppStorage(AppSettings.ignoreWhitespaceKey) private var ignoreWhitespace = false
    @AppStorage(AppSettings.listEachUntrackedFileKey) private var listEachUntrackedFile = true
    @AppStorage(AppSettings.branchOrderKey) private var branchOrder = BranchOrder.lastCommit.rawValue
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var renamingBranch: String?
    @State private var creatingBranchFrom: String?
    @State private var showingRemoteBranchSheet = false
    @State private var renameOriginal = ""
    @State private var renameDraft = ""
    @State private var createBranchSource = ""
    @State private var createBranchDraft = ""
    @State private var terminalFocus = 0
    @State private var sidebarWidth: CGFloat = 210
    @State private var historyHeight: CGFloat = 210
    @State private var stashHeight: CGFloat = 210
    @FocusState private var keyboardTarget: FocusedPane?

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
            repositoryTitle
            if session.isLoading || session.isMutating {
                loadingIndicator
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
        .onChange(of: listEachUntrackedFile) { _, _ in
            Task { await session.refreshStatus() }
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
        .sheet(isPresented: $showingRemoteBranchSheet) {
            RemoteBranchesSheet(session: session)
        }
        .alert(
            "New Branch",
            isPresented: Binding(
                get: { creatingBranchFrom != nil },
                set: { if !$0 { creatingBranchFrom = nil } }
            )
        ) {
            TextField("Branch Name", text: $createBranchDraft)
            Button("Create") {
                let source = createBranchSource
                let draft = createBranchDraft
                Task { await session.createBranch(from: source, named: draft) }
            }
            .disabled(createBranchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new branch from \(createBranchSource).")
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

    /// ボタン用のガラス背景だと、スピナーが左に寄って見える。
    @ToolbarContentBuilder
    private var loadingIndicator: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) {
                loadingIndicatorLabel
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                loadingIndicatorLabel
            }
        }
    }

    private var loadingIndicatorLabel: some View {
        ProgressView()
            .controlSize(.small)
            .padding(.leading, 8)
            .padding(.trailing, 4)
    }

    /// ガラスのタイトルバーはボタン用の余白が付く。リポジトリ名はタイトルとして置き、上下を詰める。
    @ToolbarContentBuilder
    private var repositoryTitle: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) {
                repositoryTitleLabel
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                repositoryTitleLabel
            }
        }
    }

    private var repositoryTitleLabel: some View {
        VStack(spacing: 0) {
            RecentRepositoryMenu(
                model: model,
                currentPath: session.rootPath,
                title: session.displayName
            )
            Text(session.head.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
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
            ForEach(SidebarPage.pages) { section in
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
                } else if localBranches.isEmpty && remoteBranches.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(localBranches) { branch in
                    branchRow(branch)
                }
                if !remoteBranches.isEmpty {
                    showMoreBranchesRow
                }
            } header: {
                Label("Branches", systemImage: "arrow.triangle.branch")
            }
        }
        .listStyle(.sidebar)
        .keyboardTarget(.sidebar)
    }

    /// 選択中マークとブランチ名を、サイドバーの既定位置より少し右に置く。
    private let branchMarkLeading: CGFloat = 10
    private let branchMarkWidth: CGFloat = 16

    private var localBranches: [Branch] {
        let order = BranchOrder(rawValue: branchOrder) ?? .lastCommit
        return order.sorted(session.branches.filter { $0.sync != .remoteOnly })
    }

    private var remoteBranches: [Branch] {
        session.branches.filter { $0.sync == .remoteOnly }
    }

    private var showMoreBranchesRow: some View {
        Text("Show More")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, branchMarkLeading + branchMarkWidth + 6)
            .contentShape(Rectangle())
            .onTapGesture {
                showingRemoteBranchSheet = true
            }
    }

    private func branchRow(_ branch: Branch) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .opacity(branch.isCurrent ? 1 : 0)
                    .accessibilityHidden(!branch.isCurrent)
                    .frame(width: branchMarkWidth, alignment: .center)
                    .layoutPriority(1)
                Text(branch.name)
                    .lineLimit(1)
                    .foregroundStyle(branch.sync == .remoteOnly ? .secondary : .primary)
                Spacer(minLength: 8)
            }
            .padding(.leading, branchMarkLeading)
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { checkout(branch) })
            .simultaneousGesture(TapGesture(count: 1).onEnded { focus(branch) })
            syncMark(branch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Checkout") {
                checkout(branch)
            }
            .disabled(branch.isCurrent || session.isMutating)
            Button("Copy Branch Name") {
                copyBranchName(branch.name)
            }
            Divider()
            Button("Pull") {
                Task { await session.pull(branch) }
            }
            .disabled(branch.sync != .remoteOnly && (branch.upstream == nil || branch.remoteName == nil) || session.isMutating)
            Button("Push") {
                Task { await session.push(branch) }
            }
            .disabled(branch.sync == .remoteOnly || session.isMutating || (session.remoteLink == nil && branch.remoteName == nil))
            Button("New Branch") {
                createBranchSource = branch.name
                createBranchDraft = ""
                creatingBranchFrom = branch.name
            }
            .disabled(branch.sync == .remoteOnly || session.isMutating)
            Button("Rename") {
                renameOriginal = branch.name
                renameDraft = branch.name
                renamingBranch = branch.name
            }
            .disabled(branch.sync == .remoteOnly || session.isMutating)
            Divider()
            if let target = currentBranchName, mergeSource(branch) != target {
                let source = mergeSource(branch)
                Button(String(localized: "Merge \(source) into \(target)")) {
                    session.pendingConfirm = .mergeBranch(source: source, into: target)
                }
                .disabled(session.isMutating)
            } else {
                Button("Merge") {}
                    .disabled(true)
            }
            if let current = currentBranchName, mergeSource(branch) != current {
                let onto = mergeSource(branch)
                Button(String(localized: "Rebase \(current) on top of \(onto)")) {
                    session.pendingConfirm = .rebaseBranch(name: current, upstream: onto, remote: nil)
                }
                .disabled(session.isMutating)
            } else {
                Button("Rebase") {}
                    .disabled(true)
            }
            Button("Delete", role: .destructive) {
                session.pendingConfirm = .deleteBranch(branch.name)
            }
            .disabled(branch.isCurrent || branch.sync == .remoteOnly || session.isMutating)
        }
    }

    private var currentBranchName: String? {
        guard !session.head.detached, !session.head.unborn else { return nil }
        let name = session.head.name
        guard !name.isEmpty, name != HeadState.unknown.name else { return nil }
        return name
    }

    /// ローカルブランチはその名前、リモートにしかないブランチは上流の参照をマージ元にする。
    private func mergeSource(_ branch: Branch) -> String {
        if branch.sync == .remoteOnly, let upstream = branch.upstream {
            return upstream
        }
        return branch.name
    }

    @ViewBuilder
    private func syncMark(_ branch: Branch) -> some View {
        switch branch.sync {
        case .unknown, .upToDate:
            EmptyView()
        case .notOnRemote:
            BranchSyncMenu(
                systemImage: "arrow.up",
                help: String(localized: "This branch is not on the remote"),
                showsPush: true,
                showsPull: false,
                isDisabled: session.isMutating,
                push: { Task { await session.push(branch) } },
                pull: {}
            )
        case .remoteOnly:
            BranchSyncMenu(
                systemImage: "arrow.down",
                help: String(localized: "This branch is not on this computer"),
                showsPush: false,
                showsPull: true,
                isDisabled: session.isMutating,
                push: {},
                pull: { Task { await session.pull(branch) } }
            )
        case .ahead(let count):
            BranchSyncMenu(
                systemImage: "arrow.up",
                help: aheadHelp(count),
                showsPush: true,
                showsPull: false,
                isDisabled: session.isMutating,
                push: { Task { await session.push(branch) } },
                pull: {}
            )
        case .behind(let count):
            BranchSyncMenu(
                systemImage: "arrow.down",
                help: behindHelp(count),
                showsPush: false,
                showsPull: true,
                isDisabled: session.isMutating,
                push: {},
                pull: { Task { await session.pull(branch) } }
            )
        case .diverged:
            BranchSyncMenu(
                systemImage: "arrow.up.arrow.down",
                help: String(localized: "This branch and the upstream have diverged."),
                showsPush: true,
                showsPull: true,
                isDisabled: session.isMutating,
                push: { Task { await session.push(branch) } },
                pull: { Task { await session.pull(branch) } }
            )
        }
    }

    private func aheadHelp(_ count: Int) -> String {
        if count == 1 { return String(localized: "1 commit ahead of the upstream") }
        return String(localized: "\(count) commits ahead of the upstream")
    }

    private func behindHelp(_ count: Int) -> String {
        if count == 1 { return String(localized: "1 commit behind the upstream") }
        return String(localized: "\(count) commits behind the upstream")
    }

    private func copyBranchName(_ name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    private func focus(_ branch: Branch) {
        guard !session.isMutating else { return }
        Task { await session.focusBranch(branch) }
    }

    private func checkout(_ branch: Branch) {
        guard !branch.isCurrent, !session.isMutating else { return }
        if branch.sync == .remoteOnly {
            Task { await session.checkoutRemote(branch) }
            return
        }
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

/// ローカルにないリモートブランチを、ここから取得する。
private struct RemoteBranchesSheet: View {
    var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.branchOrderKey) private var branchOrder = BranchOrder.lastCommit.rawValue

    private var branches: [Branch] {
        let order = BranchOrder(rawValue: branchOrder) ?? .lastCommit
        return order.sorted(session.branches.filter { $0.sync == .remoteOnly })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Branches")
                .font(.headline)
            if branches.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                List(branches) { branch in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(branch.name)
                                .lineLimit(1)
                            if let subject = branch.subjectLine {
                                Text(subject)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Pull") {
                            Task { await session.pull(branch) }
                        }
                        .disabled(session.isMutating)
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
                                RepositoryPathResolver.menuTitle(for: path, among: model.recent),
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
                .padding(.horizontal, 2)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .padding(.vertical, -3)
        .help(currentPath)
    }
}

private struct BranchSyncMenu: View {
    var systemImage: String
    var help: String
    var showsPush: Bool
    var showsPull: Bool
    var isDisabled: Bool
    var push: () -> Void
    var pull: () -> Void

    var body: some View {
        Group {
            if showsPush || showsPull {
                syncMenu
            } else {
                Image(systemName: systemImage)
            }
        }
        .foregroundStyle(.primary)
        .help(help)
    }

    private var menu: some View {
        Menu {
            if showsPush {
                Button("Push", action: push)
            }
            if showsPull {
                Button("Pull", action: pull)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var syncMenu: some View {
        if #available(macOS 26, *) {
            menu
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            menu
                .menuStyle(.borderlessButton)
                .tint(.primary)
        }
    }
}
