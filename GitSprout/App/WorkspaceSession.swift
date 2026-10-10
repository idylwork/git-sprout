import Foundation
import Observation

nonisolated enum ConfirmationRequest: Identifiable, Sendable {
    case discardUnstaged(FileChange)
    case discardAllUnstaged
    case discardStaged(FileChange)
    case discardHunk(String)
    case dropStash(String)
    case detach(String)
    case deleteBranch(String)
    case mergeBranch(source: String, into: String)
    case rebaseBranch(name: String, upstream: String, remote: String?)
    case pull(name: String, upstream: String, remote: String, isCurrent: Bool)
    case forcePush(branch: String, remote: String, upstream: String)
    case undoCommit

    var id: String {
        switch self {
        case .discardUnstaged(let file): return "unstaged-\(file.path)"
        case .discardAllUnstaged: return "unstaged-all"
        case .discardStaged(let file): return "staged-\(file.path)"
        case .discardHunk(let patch): return "hunk-\(patch.hashValue)"
        case .dropStash(let ref): return "stash-\(ref)"
        case .detach(let oid): return "detach-\(oid)"
        case .deleteBranch(let name): return "delete-branch-\(name)"
        case .mergeBranch(let source, let target): return "merge-\(source)-\(target)"
        case .rebaseBranch(let name, let upstream, _): return "rebase-\(name)-\(upstream)"
        case .pull(let name, let upstream, _, _): return "pull-\(name)-\(upstream)"
        case .forcePush(let branch, let remote, _): return "force-push-\(branch)-\(remote)"
        case .undoCommit: return "undo-commit"
        }
    }

    var title: String {
        switch self {
        case .discardUnstaged, .discardAllUnstaged, .discardStaged, .discardHunk:
            return String(localized: "Discard Changes?")
        case .dropStash:
            return String(localized: "Drop Stash?")
        case .detach:
            return String(localized: "Check Out This Commit?")
        case .deleteBranch:
            return String(localized: "Delete Branch?")
        case .mergeBranch:
            return String(localized: "Merge Branch?")
        case .rebaseBranch:
            return String(localized: "Rebase Branch?")
        case .pull:
            return String(localized: "Force Pull Branch?")
        case .forcePush:
            return String(localized: "Overwrite the Remote?")
        case .undoCommit:
            return String(localized: "Undo This Commit?")
        }
    }

    var message: String {
        switch self {
        case .discardUnstaged(let file), .discardStaged(let file):
            return String(localized: "Changes to \(file.displayPath) cannot be undone.")
        case .discardAllUnstaged:
            return String(localized: "Unstaged changes cannot be undone.")
        case .discardHunk:
            return String(localized: "Changes in the selected hunk cannot be undone.")
        case .dropStash:
            return String(localized: "A dropped stash cannot be restored.")
        case .detach:
            return String(localized: "This leaves the current branch and checks out the commit directly.")
        case .deleteBranch(let name):
            return String(localized: "Commits on \(name) that are not on another branch will be lost.")
        case .mergeBranch(let source, let target):
            return String(localized: "This merges \(source) into \(target).")
        case .rebaseBranch(let name, let upstream, _):
            return String(localized: "Rebase \(name) onto \(upstream).")
        case .pull(let name, let upstream, _, let isCurrent):
            if isCurrent {
                return String(localized: "Commits on \(name) and \(upstream) don't match. Force pulling discards commits that are only on this branch, and uncommitted changes.")
            }
            return String(localized: "Commits on \(name) and \(upstream) don't match. Force pulling discards commits that are only on this branch.")
        case .forcePush(_, _, let upstream):
            return String(localized: "Commits on \(upstream) don't match. Force pushing discards the remote branch's changes.")
        case .undoCommit:
            return String(localized: "HEAD moves to the parent commit. The changes stay staged.")
        }
    }

    var confirmTitle: String {
        switch self {
        case .discardUnstaged, .discardAllUnstaged, .discardStaged, .discardHunk:
            return String(localized: "Discard")
        case .dropStash:
            return String(localized: "Drop")
        case .detach:
            return String(localized: "Checkout")
        case .deleteBranch:
            return String(localized: "Delete")
        case .mergeBranch:
            return String(localized: "Merge")
        case .rebaseBranch:
            return String(localized: "Rebase")
        case .pull:
            return String(localized: "Force Pull")
        case .forcePush:
            return String(localized: "Force Push")
        case .undoCommit:
            return String(localized: "Undo Commit")
        }
    }

    var isDestructive: Bool {
        switch self {
        case .mergeBranch, .rebaseBranch:
            return false
        default:
            return true
        }
    }
}

struct HistoryScrollRequest: Equatable {
    var oid: String
    var token: Int
}

/// 画面に出すデータだけを持つ。git の実行とパースは `GitClient` が別スレッドで行う。
/// 履歴、ファイル履歴、差分、検索は必要になった分だけ読む。
@MainActor
@Observable
final class WorkspaceSession {
    let client: GitClient
    let rootPath: String

    var section: SidebarPage = .commits
    var head = HeadState.unknown
    var errorMessage: String?
    var pendingConfirm: ConfirmationRequest?
    var terminalVisible = false
    var didActivateOnce = false
    private(set) var loadCount = 0

    var changes: [FileChange] = []
    var statusTruncated = false
    var focusedWork: FileSelection?
    var diff: DiffDocument?
    var branchesExpanded = true
    var diffLoading = false
    var commitMessage = ""
    var isMutating = false

    var graphRows: [GraphRow] = []
    var graphCursor = GraphCursor.empty
    var historyHasMore = false
    var historyLoading = false
    var historyLoadingMore = false
    var historyDirty = true
    var selectedCommit: String?
    /// 選択コミットを base、現在の HEAD を head にした三点差分のシート。履歴の表示とは別。
    var rangeBase: String?
    var rangeFiles: [PathStatus] = []
    var rangeFilesCapped = false
    var rangeFilesLoading = false
    var rangePath: String?
    var rangeDiff: DiffDocument?
    var rangeDiffLoading = false
    var historyFocus: HistoryScrollRequest?
    var commitFiles: [PathStatus] = []
    var commitFilesCapped = false
    var commitFilesLoading = false
    var selectedCommitPath: String?

    var showsUncommitted: Bool { selectedCommit == CommitRecord.uncommittedOID }

    var showsRangeDiff: Bool { rangeBase != nil }

    /// `abcdef…main` のように、比較の両端を短く示す。
    var rangeDiffTitle: String? {
        guard showsRangeDiff, let rangeBase else { return nil }
        return "\(rangeBase.prefix(7))…\(head.title)"
    }

    var selectedCommitRecord: CommitRecord? {
        guard let oid = selectedCommit, oid != CommitRecord.uncommittedOID else { return nil }
        return graphRows.first { $0.id == oid }?.commit
    }

    /// 作業ツリーに変更があるとき、行をグラフの先頭に足し、チェックアウト中のコミットへつなぐ。
    /// 変更がないときは、その接続のために空けたレーンの上向きの線を消す。
    var historyRows: [GraphRow] {
        guard changeCount > 0 else {
            return GraphLayout.omittingUnusedHeadLine(graphRows, head: head.oid)
        }
        return GraphLayout.insertingUncommitted(graphRows, aboveHead: head.oid)
    }
    var commitDiff: DiffDocument?
    var commitDiffLoading = false

    var branches: [Branch] = []
    var branchesLoading = false
    var remoteLink: RemoteLink?

    var stashes: [StashEntry] = []
    var selectedStash: String?
    var stashFiles: [PathStatus] = []
    var stashFilesCapped = false
    var stashFilesLoading = false
    var selectedStashPath: String?
    var stashDiff: DiffDocument?
    var stashDiffLoading = false
    var stashMessage = ""

    var fileHistoryPath: String?
    var fileCommits: [CommitRecord] = []
    var fileHistoryHasMore = false
    var fileHistoryLoading = false
    var fileHistoryLoadingMore = false
    var selectedFileRevision: String?
    var fileBodyMode: FileHistoryDisplayMode = .content
    var fileBlob: FileBlob?
    var fileParentDiff: DiffDocument?
    var fileBodyLoading = false

    var searchKind: SearchScope = .message
    var searchQuery = ""
    var commitHits: [CommitRecord] = []
    var pathHits: [String] = []
    var contentHits: [ContentHit] = []
    var searchCapped = false
    var searchLoading = false
    var selectedSearchCommit: String?
    var searchCommitFiles: [PathStatus] = []
    var searchCommitPath: String?
    var searchDiff: DiffDocument?

    private var loadedHistoryCount = 0
    private var loadedFileHistoryCount = 0
    private var historyTicket = 0
    private var branchesTicket = 0
    private var fileHistoryTicket = 0
    private var diffTicket = 0
    private var searchTicket = 0
    private var commitTicket = 0
    private var rangeTicket = 0
    private var stashTicket = 0
    private var focusToken = 0
    private let watcher = RepoWatcher()

    var displayName: String {
        URL(fileURLWithPath: rootPath).lastPathComponent
    }

    var isLoading: Bool { loadCount > 0 }

    var stagedChanges: [FileChange] { changes.filter(\.hasStaged) }
    var unstagedChanges: [FileChange] { changes.filter(\.hasUnstaged) }
    var changeCount: Int { Set(changes.map(\.path)).count }
    var hasStaged: Bool { changes.contains(where: \.hasStaged) }

    init(rootPath: String) {
        self.rootPath = rootPath
        self.client = GitClient(workingDirectory: rootPath)
    }

    func startWatching() {
        watcher.start(root: rootPath) { [weak self] change in
            await self?.refreshForFilesystem(change)
        }
    }

    func stopWatching() {
        watcher.stop()
    }

    func initialLoad() async {
        await refreshHead()
        await refreshStatus()
        await refreshBranches()
        await loadSectionIfNeeded()
    }

    func refreshActive() async {
        await refreshHead()
        await refreshBranches()
        switch section {
        case .commits:
            await refreshStatus()
            await reloadHistory()
        case .branches:
            break
        case .stashes:
            await refreshStashes()
        case .search:
            break
        }
        if fileHistoryPath != nil {
            await reloadFileHistory()
        }
    }

    /// ファイルの保存は status だけ、参照の更新は履歴まで読み直す。
    func refreshForFilesystem(_ change: RepoChange) async {
        guard !isMutating else { return }
        if change.refsChanged {
            await refreshActive()
            return
        }
        guard change.worktreeOverflow || !change.worktreePaths.isEmpty else { return }
        if !change.worktreeOverflow, change.worktreePaths.count > RepoChange.ignoreProbeLimit {
            do {
                let ignored = try await client.ignored(among: change.worktreePaths)
                if change.worktreePaths.allSatisfy({ ignored.contains($0) }) {
                    return
                }
            } catch {
                // 判定できないときは status を読んで取りこぼさない
            }
        }
        await refreshStatus()
    }

    func loadSectionIfNeeded() async {
        switch section {
        case .commits:
            if changes.isEmpty { await refreshStatus() }
            if graphRows.isEmpty || historyDirty { await reloadHistory() }
        case .branches:
            break
        case .stashes:
            if stashes.isEmpty { await refreshStashes() }
        case .search:
            break
        }
    }

    func refreshStatus() async {
        await track {
            do {
                let snapshot = try await client.status(listEachUntrackedFile: AppSettings.listEachUntrackedFile)
                changes = snapshot.files
                statusTruncated = snapshot.truncated
                if changeCount == 0, selectedCommit == CommitRecord.uncommittedOID {
                    selectedCommit = nil
                    selectedCommitPath = nil
                    commitDiff = nil
                }
                if let focusedWork, focusedWork.commitOID == nil {
                    let matches = changes.contains { file in
                        file.path == focusedWork.path && (focusedWork.staged ? file.hasStaged : file.hasUnstaged)
                    }
                    if !matches {
                        let flipped = FileSelection(path: focusedWork.path, staged: !focusedWork.staged)
                        let flippedMatches = changes.contains { file in
                            file.path == flipped.path && (flipped.staged ? file.hasStaged : file.hasUnstaged)
                        }
                        self.focusedWork = flippedMatches ? flipped : nil
                    }
                }
                await loadWorkDiff()
            } catch {
                report(error)
            }
        }
    }

    func refreshHead() async {
        let previous = head.oid
        do {
            head = try await client.head()
        } catch {
            report(error)
            return
        }
        guard showsRangeDiff, head.oid != previous else { return }
        await loadRangeFiles()
    }

    func reloadOpenDiffs() async {
        await loadWorkDiff()
        if let path = selectedCommitPath {
            await selectCommitFile(path)
        }
        if let path = selectedStashPath {
            await selectStashFile(path)
        }
        if fileBodyMode == .parentDiff {
            await loadFileBody()
        }
        if let path = searchCommitPath {
            await selectSearchCommitFile(path)
        }
        if let path = rangePath {
            await selectRangeFile(path)
        }
    }

    func focusWork(_ file: FileSelection?) async {
        focusedWork = file
        await loadWorkDiff()
    }

    func loadWorkDiff() async {
        guard let focusedWork, focusedWork.commitOID == nil else {
            if focusedWork == nil {
                diff = nil
            }
            return
        }
        diffTicket += 1
        let ticket = diffTicket
        let path = focusedWork.path
        let staged = focusedWork.staged
        diffLoading = true
        defer { if ticket == diffTicket { diffLoading = false } }
        do {
            let original = changes.first { $0.path == path }?.originalPath
            let document = try await client.diff(
                path: path,
                originalPath: original,
                staged: staged,
                ignoringWhitespace: AppSettings.ignoreWhitespace
            )
            guard ticket == diffTicket else { return }
            diff = document
        } catch {
            guard ticket == diffTicket else { return }
            report(error)
        }
    }

    func toggleStage(_ files: [FileSelection]) async {
        guard !files.isEmpty else { return }
        let stagePaths = files.filter { $0.commitOID == nil && !$0.staged }.map(\.path)
        let unstagePaths = files.filter { $0.commitOID == nil && $0.staged }.map(\.path)
        let fromCommits = Dictionary(grouping: files.filter { $0.commitOID != nil }, by: \.commitOID)
        await mutate {
            if !stagePaths.isEmpty {
                try await client.stage(paths: stagePaths)
            }
            if !unstagePaths.isEmpty {
                try await client.unstage(paths: unstagePaths)
            }
            for (oid, items) in fromCommits {
                guard let oid else { continue }
                try await client.stage(from: oid, paths: items.map(\.path))
            }
        }
    }

    func stage(paths: [String]) async {
        await mutate {
            try await client.stage(paths: paths)
        }
    }

    func unstage(paths: [String]) async {
        await mutate {
            try await client.unstage(paths: paths)
        }
    }

    func stageHunk(_ hunk: DiffHunk) async {
        let unstage = focusedWork?.staged == true && focusedWork?.commitOID == nil
        await mutate {
            try await client.apply(patch: hunk.patch, cached: true, reverse: unstage)
        }
    }

    func stageCommitHunk(_ hunk: DiffHunk) async {
        await mutate {
            try await client.apply(patch: hunk.patch, cached: true, reverse: false)
        }
    }

    func stageLines(_ patch: String) async {
        let unstage = focusedWork?.staged == true && focusedWork?.commitOID == nil
        await mutate {
            try await client.apply(patch: patch, cached: true, reverse: unstage)
        }
    }

    func appendTrailingNewline(path: String, staged: Bool) async {
        await mutate {
            try await client.appendTrailingNewline(path: path, staged: staged)
        }
    }

    func stageCommitLines(_ patch: String) async {
        await mutate {
            try await client.apply(patch: patch, cached: true, reverse: false)
        }
    }

    func latestCommitMessage() async throws -> String {
        try await client.headCommitMessage()
    }

    func commit(message: String, amend: Bool) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            try await client.commit(message: message, amend: amend)
            if !amend {
                commitMessage = ""
            }
            historyDirty = true
            await refreshHead()
            await refreshStatus()
            await refreshBranches()
            if section == .commits {
                await reloadHistory()
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func reloadHistory() async {
        historyTicket += 1
        let ticket = historyTicket
        historyLoading = true
        defer { if ticket == historyTicket { historyLoading = false } }
        do {
            let page = try await client.log(skip: 0, limit: GitLimits.pageSize)
            let headOID = head.oid
            let laid = await BackgroundWork.run { GraphLayout.layout(commits: page.commits, cursor: .empty, head: headOID) }
            guard ticket == historyTicket else { return }
            graphRows = laid.rows
            graphCursor = laid.cursor
            historyHasMore = page.hasMore
            loadedHistoryCount = page.commits.count
            historyDirty = false
        } catch {
            guard ticket == historyTicket else { return }
            report(error)
        }
    }

    func loadMoreHistory() async {
        guard historyHasMore, !historyLoadingMore, !historyLoading else { return }
        historyLoadingMore = true
        defer { historyLoadingMore = false }
        let ticket = historyTicket
        let skip = loadedHistoryCount
        let cursor = graphCursor
        let headOID = head.oid
        do {
            let page = try await client.log(skip: skip, limit: GitLimits.pageSize)
            let laid = await BackgroundWork.run { GraphLayout.layout(commits: page.commits, cursor: cursor, head: headOID) }
            guard ticket == historyTicket else { return }
            graphRows.append(contentsOf: laid.rows)
            graphCursor = laid.cursor
            historyHasMore = page.hasMore
            loadedHistoryCount += page.commits.count
        } catch {
            guard ticket == historyTicket else { return }
            report(error)
        }
    }

    func prefetchHistory(oid: String) async {
        guard let index = graphRows.firstIndex(where: { $0.id == oid }) else { return }
        guard index >= graphRows.count - 12 else { return }
        await loadMoreHistory()
    }

    func focusBranch(_ branch: Branch) async {
        let oid = branch.oid
        guard !oid.isEmpty else { return }
        closeFileHistory()
        section = .commits
        if graphRows.isEmpty || historyDirty {
            await reloadHistory()
        }
        var pages = 0
        while !graphRows.contains(where: { $0.id == oid }), historyHasMore, pages < 50 {
            let before = loadedHistoryCount
            await loadMoreHistory()
            pages += 1
            if loadedHistoryCount == before { break }
        }
        revealHistory(oid)
        await selectCommit(oid)
    }

    func revealHistory(_ oid: String) {
        focusToken += 1
        historyFocus = HistoryScrollRequest(oid: oid, token: focusToken)
    }

    func selectCommit(_ oid: String) async {
        if rangeBase != nil, rangeBase != oid {
            dismissRangeDiff()
        }
        selectedCommit = oid
        selectedCommitPath = nil
        commitDiff = nil
        commitDiffLoading = false
        guard oid != CommitRecord.uncommittedOID else {
            commitFiles = []
            commitFilesCapped = false
            return
        }
        commitTicket += 1
        let ticket = commitTicket
        commitFilesLoading = true
        defer { if ticket == commitTicket { commitFilesLoading = false } }
        do {
            let list = try await client.files(in: oid)
            guard ticket == commitTicket else { return }
            commitFiles = list.values
            commitFilesCapped = list.capped
        } catch {
            guard ticket == commitTicket else { return }
            report(error)
        }
    }

    func showRangeDiff() async {
        guard let oid = selectedCommit, oid != CommitRecord.uncommittedOID else { return }
        guard !head.oid.isEmpty, oid != head.oid else { return }
        rangeBase = oid
        rangePath = nil
        rangeDiff = nil
        rangeDiffLoading = false
        await loadRangeFiles()
    }

    func dismissRangeDiff() {
        guard rangeBase != nil else { return }
        closeFileHistory()
        rangeTicket += 1
        rangeBase = nil
        rangeFiles = []
        rangeFilesCapped = false
        rangeFilesLoading = false
        rangePath = nil
        rangeDiff = nil
        rangeDiffLoading = false
    }

    func selectCommitFile(_ path: String) async {
        guard let oid = selectedCommit else { return }
        selectedCommitPath = path
        commitDiffLoading = true
        let ticket = commitTicket
        defer { if ticket == commitTicket { commitDiffLoading = false } }
        do {
            let original = commitFiles.first { $0.path == path }?.originalPath
            let document = try await client.showFileDiff(
                oid: oid,
                path: path,
                originalPath: original,
                ignoringWhitespace: AppSettings.ignoreWhitespace
            )
            guard ticket == commitTicket else { return }
            commitDiff = document
        } catch {
            guard ticket == commitTicket else { return }
            report(error)
        }
    }

    func selectRangeFile(_ path: String) async {
        guard let base = rangeBase, !head.oid.isEmpty else { return }
        rangePath = path
        rangeDiffLoading = true
        let ticket = rangeTicket
        let headOID = head.oid
        defer { if ticket == rangeTicket { rangeDiffLoading = false } }
        do {
            let original = rangeFiles.first { $0.path == path }?.originalPath
            let document = try await client.rangeFileDiff(
                base: base,
                head: headOID,
                path: path,
                originalPath: original,
                ignoringWhitespace: AppSettings.ignoreWhitespace
            )
            guard ticket == rangeTicket, rangePath == path else { return }
            rangeDiff = document
        } catch {
            guard ticket == rangeTicket, rangePath == path else { return }
            report(error)
        }
    }

    private func loadRangeFiles() async {
        guard let base = rangeBase, !head.oid.isEmpty else { return }
        let headOID = head.oid
        rangeTicket += 1
        let ticket = rangeTicket
        rangeFilesLoading = true
        defer { if ticket == rangeTicket { rangeFilesLoading = false } }
        do {
            let list = try await client.files(from: base, to: headOID)
            guard ticket == rangeTicket, rangeBase == base else { return }
            rangeFiles = list.values
            rangeFilesCapped = list.capped
            if let path = rangePath, list.values.contains(where: { $0.path == path }) {
                await selectRangeFile(path)
            } else if rangePath != nil {
                rangePath = nil
                rangeDiff = nil
            }
        } catch {
            guard ticket == rangeTicket, rangeBase == base else { return }
            report(error)
        }
    }

    func refreshBranches() async {
        branchesTicket += 1
        let ticket = branchesTicket
        branchesLoading = true
        defer { if ticket == branchesTicket { branchesLoading = false } }
        do {
            let listed = try await client.branches()
            guard ticket == branchesTicket else { return }
            branches = listed
        } catch {
            guard ticket == branchesTicket else { return }
            report(error)
        }
        guard ticket == branchesTicket else { return }
        await refreshRemoteLink()
    }

    /// 今のブランチが追跡するリモートを優先し、なければ origin を使う。
    private func refreshRemoteLink() async {
        let preferred = branches.first(where: \.isCurrent)?.remoteName
        do {
            remoteLink = try await client.remoteLink(preferredRemote: preferred)
        } catch {
            remoteLink = nil
        }
    }

    func push(_ branch: Branch) async {
        guard !isMutating else { return }
        let remote = branch.remoteName ?? remoteLink?.name
        guard let remote else {
            errorMessage = String(localized: "This repository has no remote.")
            return
        }
        if let upstream = branch.upstream, branch.remoteName != nil {
            let divergence: UpstreamRelation
            do {
                divergence = try await client.pushDivergence(branch: branch.name, upstream: upstream)
            } catch {
                report(error)
                return
            }
            switch divergence {
            case .diverged:
                pendingConfirm = .forcePush(branch: branch.name, remote: remote, upstream: upstream)
                return
            case .behind:
                errorMessage = String(localized: "The remote has commits that are not on this branch.")
                return
            case .upToDate, .fastForward:
                break
            }
        }
        await send(branch: branch.name, remote: remote, forceWithLease: false, setUpstream: branch.remoteName == nil)
    }

    /// 上流を取得して早送りする。履歴が分かれているときは、確認のあと強制的に上流へ合わせる。
    func pull(_ branch: Branch) async {
        guard !isMutating else { return }
        if branch.sync == .remoteOnly {
            guard let upstream = branch.upstream else { return }
            await mutate {
                try await client.trackRemoteBranch(branch.name, upstream: upstream, checkout: false)
                await refreshBranches()
            }
            return
        }
        guard let upstream = branch.upstream, let remote = branch.remoteName else { return }
        let divergence: UpstreamRelation
        isMutating = true
        do {
            divergence = try await client.pullDivergence(branch: branch.name, upstream: upstream, remote: remote)
        } catch {
            isMutating = false
            report(error)
            return
        }
        isMutating = false
        await refreshBranches()
        switch divergence {
        case .diverged:
            pendingConfirm = .pull(
                name: branch.name,
                upstream: upstream,
                remote: remote,
                isCurrent: branch.isCurrent
            )
        case .behind:
            await mutate {
                try await client.fastForward(
                    branch: branch.name,
                    upstream: upstream,
                    remote: remote,
                    isCurrent: branch.isCurrent,
                    fetches: false
                )
                await refreshBranches()
                if branch.isCurrent, section == .commits {
                    await reloadHistory()
                }
            }
        case .upToDate, .fastForward:
            break
        }
    }

    func switchBranch(_ name: String) async {
        await mutate {
            try await client.switchBranch(name)
            await reloadAfterCheckout()
        }
    }

    func checkoutRemote(_ branch: Branch) async {
        guard let upstream = branch.upstream else { return }
        await mutate {
            try await client.trackRemoteBranch(branch.name, upstream: upstream, checkout: true)
            await reloadAfterCheckout()
        }
    }

    func createBranch(from startPoint: String, named newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await mutate {
            try await client.createBranch(trimmed, from: startPoint)
            await refreshBranches()
        }
    }

    func renameBranch(_ name: String, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        await mutate {
            try await client.renameBranch(name, to: trimmed)
            await refreshBranches()
        }
    }

    func confirmDetach(_ oid: String) {
        pendingConfirm = .detach(oid)
    }

    func confirmUndoCommit() {
        pendingConfirm = .undoCommit
    }

    func refreshStashes() async {
        do {
            stashes = try await client.stashes()
            if let selectedStash, !stashes.contains(where: { $0.ref == selectedStash }) {
                self.selectedStash = nil
                clearStashDetail()
            }
        } catch {
            report(error)
        }
    }

    func selectStash(_ ref: String) async {
        selectedStash = ref
        clearStashDetail()
        stashTicket += 1
        let ticket = stashTicket
        stashFilesLoading = true
        defer { if ticket == stashTicket { stashFilesLoading = false } }
        do {
            let list = try await client.stashFiles(ref)
            guard ticket == stashTicket else { return }
            stashFiles = list.values
            stashFilesCapped = list.capped
        } catch {
            guard ticket == stashTicket else { return }
            report(error)
        }
    }

    func selectStashFile(_ path: String) async {
        guard let ref = selectedStash else { return }
        selectedStashPath = path
        stashDiff = nil
        stashDiffLoading = true
        let ticket = stashTicket
        do {
            let original = stashFiles.first { $0.path == path }?.originalPath
            let document = try await client.stashFileDiff(
                ref: ref,
                path: path,
                originalPath: original,
                ignoringWhitespace: AppSettings.ignoreWhitespace
            )
            guard ticket == stashTicket, selectedStashPath == path else { return }
            stashDiff = document
            stashDiffLoading = false
        } catch {
            guard ticket == stashTicket, selectedStashPath == path else { return }
            stashDiffLoading = false
            report(error)
        }
    }

    private func clearStashDetail() {
        stashFiles = []
        stashFilesCapped = false
        selectedStashPath = nil
        stashDiff = nil
        stashDiffLoading = false
    }

    func createStash(message custom: String? = nil, unstagedOnly: Bool = false) async {
        let message = (custom ?? stashMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        await mutate {
            try await client.stashPush(
                message: message.isEmpty ? nil : message,
                includeUntracked: AppSettings.stashIncludeUntracked,
                unstagedOnly: unstagedOnly
            )
            if custom == nil {
                stashMessage = ""
            }
            await refreshStashes()
        }
    }

    func applyStash(_ ref: String, pop: Bool) async {
        await mutate {
            if pop {
                try await client.stashPop(ref)
            } else {
                try await client.stashApply(ref)
            }
            await refreshStashes()
        }
    }

    func openFileHistory(_ path: String) async {
        fileHistoryPath = path
        fileBodyMode = .content
        selectedFileRevision = nil
        fileBlob = nil
        fileParentDiff = nil
        await reloadFileHistory()
    }

    func closeFileHistory() {
        fileHistoryPath = nil
        fileCommits = []
        selectedFileRevision = nil
        fileBlob = nil
        fileParentDiff = nil
    }

    func reloadFileHistory() async {
        guard let path = fileHistoryPath else { return }
        fileHistoryTicket += 1
        let ticket = fileHistoryTicket
        fileHistoryLoading = true
        defer { if ticket == fileHistoryTicket { fileHistoryLoading = false } }
        do {
            let page = try await client.fileLog(path: path, skip: 0, limit: GitLimits.pageSize)
            guard ticket == fileHistoryTicket else { return }
            fileCommits = page.commits
            fileHistoryHasMore = page.hasMore
            loadedFileHistoryCount = page.commits.count
        } catch {
            guard ticket == fileHistoryTicket else { return }
            report(error)
        }
    }

    func loadMoreFileHistory() async {
        guard let path = fileHistoryPath, fileHistoryHasMore, !fileHistoryLoadingMore, !fileHistoryLoading else { return }
        fileHistoryLoadingMore = true
        defer { fileHistoryLoadingMore = false }
        let ticket = fileHistoryTicket
        let skip = loadedFileHistoryCount
        do {
            let page = try await client.fileLog(path: path, skip: skip, limit: GitLimits.pageSize)
            guard ticket == fileHistoryTicket else { return }
            fileCommits.append(contentsOf: page.commits)
            fileHistoryHasMore = page.hasMore
            loadedFileHistoryCount += page.commits.count
        } catch {
            guard ticket == fileHistoryTicket else { return }
            report(error)
        }
    }

    func prefetchFileHistory(oid: String) async {
        guard let index = fileCommits.firstIndex(where: { $0.oid == oid }) else { return }
        guard index >= fileCommits.count - 12 else { return }
        await loadMoreFileHistory()
    }

    func selectFileRevision(_ oid: String) async {
        selectedFileRevision = oid
        fileBlob = nil
        fileParentDiff = nil
        await loadFileBody()
    }

    func loadFileBody() async {
        guard let path = fileHistoryPath, let rev = selectedFileRevision else { return }
        fileBodyLoading = true
        defer { fileBodyLoading = false }
        do {
            switch fileBodyMode {
            case .content:
                fileBlob = try await client.file(at: rev, path: path)
            case .parentDiff:
                fileParentDiff = try await client.fileParentDiff(
                    rev: rev,
                    path: path,
                    ignoringWhitespace: AppSettings.ignoreWhitespace
                )
            }
        } catch {
            report(error)
        }
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTicket += 1
        let ticket = searchTicket
        let kind = searchKind
        searchLoading = true
        defer { if ticket == searchTicket { searchLoading = false } }
        do {
            switch kind {
            case .message:
                let result = try await client.searchCommits(query: query)
                guard ticket == searchTicket else { return }
                commitHits = result.values
                pathHits = []
                contentHits = []
                searchCapped = result.capped
            case .path:
                let result = try await client.searchPaths(query: query)
                guard ticket == searchTicket else { return }
                pathHits = result.values
                commitHits = []
                contentHits = []
                searchCapped = result.capped
            case .content:
                let result = try await client.searchContent(query: query)
                guard ticket == searchTicket else { return }
                contentHits = result.values
                commitHits = []
                pathHits = []
                searchCapped = result.capped
            }
        } catch {
            guard ticket == searchTicket else { return }
            report(error)
        }
    }

    func selectSearchCommit(_ oid: String) async {
        selectedSearchCommit = oid
        searchCommitPath = nil
        searchDiff = nil
        do {
            searchCommitFiles = try await client.files(in: oid).values
        } catch {
            report(error)
        }
    }

    func selectSearchCommitFile(_ path: String) async {
        guard let oid = selectedSearchCommit else { return }
        searchCommitPath = path
        do {
            let original = searchCommitFiles.first { $0.path == path }?.originalPath
            searchDiff = try await client.showFileDiff(
                oid: oid,
                path: path,
                originalPath: original,
                ignoringWhitespace: AppSettings.ignoreWhitespace
            )
        } catch {
            report(error)
        }
    }

    func perform(_ confirm: ConfirmationRequest) async {
        pendingConfirm = nil
        switch confirm {
        case .discardUnstaged(let file):
            await mutate { try await client.discardUnstaged([file]) }
        case .discardAllUnstaged:
            let files = unstagedChanges
            guard !files.isEmpty else { return }
            await mutate { try await client.discardUnstaged(files) }
        case .discardStaged(let file):
            await mutate { try await client.discardStaged([file]) }
        case .discardHunk(let patch):
            await mutate { try await client.apply(patch: patch, cached: false, reverse: true) }
        case .dropStash(let ref):
            await mutate {
                try await client.stashDrop(ref)
                await refreshStashes()
            }
        case .detach(let oid):
            await mutate {
                try await client.detach(oid: oid)
                await reloadAfterCheckout()
            }
        case .deleteBranch(let name):
            await mutate {
                try await client.deleteBranch(name)
                await refreshBranches()
            }
        case .mergeBranch(let source, let target):
            await mutate {
                try await client.merge(source, into: target)
                await reloadAfterCheckout()
            }
        case .rebaseBranch(let name, let upstream, let remote):
            await mutate {
                try await client.rebase(branch: name, onto: upstream, remote: remote)
                await reloadAfterCheckout()
            }
        case .pull(let name, let upstream, let remote, let isCurrent):
            await mutate {
                try await client.matchRemote(branch: name, upstream: upstream, remote: remote, isCurrent: isCurrent)
                if isCurrent {
                    await reloadAfterCheckout()
                } else {
                    await refreshBranches()
                }
            }
        case .forcePush(let branch, let remote, _):
            await send(branch: branch, remote: remote, forceWithLease: true, setUpstream: false)
        case .undoCommit:
            let previous = head.oid
            await mutate {
                try await client.undoHeadCommit()
                await reloadAfterCheckout()
            }
            guard head.oid != previous, !head.oid.isEmpty else { return }
            revealHistory(head.oid)
            await selectCommit(head.oid)
        }
    }

    private func send(branch: String, remote: String, forceWithLease: Bool, setUpstream: Bool) async {
        await mutate {
            try await client.push(remote: remote, branch: branch, forceWithLease: forceWithLease, setUpstream: setUpstream)
            await refreshBranches()
        }
    }

    private func reloadAfterCheckout() async {
        historyDirty = true
        await refreshHead()
        await refreshStatus()
        await refreshBranches()
        if section == .commits {
            await reloadHistory()
        }
    }

    private func mutate(_ body: () async throws -> Void) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await body()
            historyDirty = true
            await refreshHead()
            await refreshStatus()
        } catch {
            report(error)
            await refreshStatus()
        }
    }

    private func track(_ body: () async -> Void) async {
        loadCount += 1
        defer { loadCount -= 1 }
        await body()
    }

    private func report(_ error: Error) {
        if error is GitCancelled || error is CancellationError { return }
        errorMessage = (error as? GitFailure)?.message ?? error.localizedDescription
    }
}
