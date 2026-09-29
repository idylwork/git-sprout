//
//  GitClient.swift
//  GitSprout
//

import Foundation

/// git の起動、パイプ読み取り、パースはメインスレッドの外で行う。
/// 同じ種類の読み取りをやり直すときは、前のプロセスを止める。
actor GitClient {
    let workingDirectory: String

    private var inflight: [String: GitProcessBox] = [:]
    private var writeLocked = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    static func resolveRepository(at path: String) async throws -> String {
        let output = try await GitProcessBox().run(
            Self.makeRequest(repo: path, args: ["rev-parse", "--show-toplevel"], limit: 4096),
            cancelOnTaskCancel: true
        )
        guard output.status == 0 else {
            throw GitFailure(message: failureText(output, fallback: String(localized: "Not a Git repository.")))
        }
        let root = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw GitFailure(message: String(localized: "Not a Git repository."))
        }
        return root
    }

    func head() async throws -> HeadState {
        let branch = try await capture(key: "head", args: ["branch", "--show-current"], limit: 1024, preempt: true)
        let oid = try await capture(key: "head", args: ["rev-parse", "--verify", "HEAD"], limit: 128, preempt: true)
        let name = String(decoding: branch.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = String(decoding: oid.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if oid.status != 0 {
            return HeadState(name: name.isEmpty ? "main" : name, oid: "", detached: false, unborn: true)
        }
        if name.isEmpty {
            return HeadState(name: String(hash.prefix(7)), oid: hash, detached: true, unborn: false)
        }
        return HeadState(name: name, oid: hash, detached: false, unborn: false)
    }

    func status() async throws -> StatusSnapshot {
        let output = try await capture(
            key: "status",
            args: ["status", "--porcelain=v2", "-z", "--untracked-files=normal"],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the list of changes."))
        let files = await Self.parse(output.stdout) { GitStatusParser.parse($0) }
        return StatusSnapshot(files: files, truncated: output.truncated)
    }

    func diff(path: String, originalPath: String? = nil, staged: Bool, ignoringWhitespace: Bool = false) async throws -> DiffDocument {
        var args = ["diff", "--find-renames", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        if staged { args.append("--cached") }
        args.append("--")
        if let originalPath, originalPath != path {
            args.append(originalPath)
        }
        args.append(path)
        var document = try await diffOutput(key: "diff", args: args)
        if !staged, document.isEmpty, let added = try await untrackedWorktreeDiff(path: path, ignoringWhitespace: ignoringWhitespace) {
            document = added
        }
        return try await addingWorktreeImages(document, path: path, originalPath: originalPath, staged: staged)
    }

    func showFileDiff(oid: String, path: String, originalPath: String? = nil, ignoringWhitespace: Bool = false) async throws -> DiffDocument {
        var args = ["show", "--first-parent", "--format=", "--find-renames", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        args.append(contentsOf: [oid, "--"])
        if let originalPath, originalPath != path {
            args.append(originalPath)
        }
        args.append(path)
        let document = try await diffOutput(key: "diff", args: args)
        return try await addingCommitImages(document, oid: oid, path: path, originalPath: originalPath)
    }

    /// `base...head`。merge-base から head までで、プルリクエストの差分と同じ範囲。
    func rangeFileDiff(
        base: String,
        head: String,
        path: String,
        originalPath: String? = nil,
        ignoringWhitespace: Bool = false
    ) async throws -> DiffDocument {
        var args = ["diff", "--find-renames", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        args.append(contentsOf: ["\(base)...\(head)", "--"])
        if let originalPath, originalPath != path {
            args.append(originalPath)
        }
        args.append(path)
        let document = try await diffOutput(key: "diff", args: args)
        let oldPath = originalPath ?? document.renameFrom ?? path
        guard !document.truncated, !document.isEmpty else { return document }
        guard ImagePaths.isImage(path) || ImagePaths.isImage(oldPath) else { return document }
        let fork = try await mergeBase(base, head)
        return try await addingObjectImages(
            document,
            beforeRev: fork,
            beforePath: oldPath,
            afterRev: head,
            afterPath: path
        )
    }

    func stage(paths: [String]) async throws {
        try await mutate(paths: paths, fallback: String(localized: "Couldn't stage the changes.")) { chunk in
            ["add", "--"] + chunk
        }
    }

    /// 指定コミットの内容をインデックスへ入れる。作業ツリーは変えない。
    func stage(from oid: String, paths: [String]) async throws {
        try await mutate(paths: paths, fallback: String(localized: "Couldn't stage the changes.")) { chunk in
            ["restore", "--source", oid, "--staged", "--"] + chunk
        }
    }

    func unstage(paths: [String]) async throws {
        try await mutate(paths: paths, fallback: String(localized: "Couldn't unstage the changes.")) { chunk in
            ["restore", "--staged", "--"] + chunk
        }
    }

    func discardUnstaged(_ files: [FileChange]) async throws {
        let untracked = files.filter { $0.unstaged == .untracked }.map(\.path)
        let tracked = files.filter { $0.hasUnstaged && $0.unstaged != .untracked }.map(\.path)
        try await withWrite {
            if !tracked.isEmpty {
                try await self.mutateUnlocked(paths: tracked, fallback: String(localized: "Couldn't discard the changes.")) { chunk in
                    ["restore", "--worktree", "--"] + chunk
                }
            }
            if !untracked.isEmpty {
                try await self.mutateUnlocked(paths: untracked, fallback: String(localized: "Couldn't discard the untracked files.")) { chunk in
                    ["clean", "-f", "--"] + chunk
                }
            }
        }
    }

    func discardStaged(_ files: [FileChange]) async throws {
        try await mutate(paths: files.map(\.path), fallback: String(localized: "Couldn't discard the staged changes.")) { chunk in
            ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + chunk
        }
    }

    func apply(patch: String, cached: Bool, reverse: Bool) async throws {
        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        var data = Data(patch.utf8)
        if !patch.hasSuffix("\n") {
            data.append(0x0A)
        }
        try await withWrite {
            let output = try await self.capture(key: "apply", args: args, input: data, limit: 65_536, preempt: false)
            try self.requireOK(output, fallback: String(localized: "Couldn't apply the patch."))
        }
    }

    func commit(message: String, amend: Bool = false) async throws {
        try await withWrite {
            var args = ["commit"]
            if amend {
                args.append("--amend")
            }
            args.append(contentsOf: ["-m", message])
            let output = try await self.capture(
                key: "commit",
                args: args,
                limit: 65_536,
                preempt: false
            )
            let fallback = amend
                ? String(localized: "Couldn't amend the commit.")
                : String(localized: "Couldn't commit.")
            try self.requireOK(output, fallback: fallback)
        }
    }

    /// HEAD のメッセージ全文。末尾の改行は除く。
    func headCommitMessage() async throws -> String {
        let output = try await capture(
            key: "head-message",
            args: ["log", "-1", "--format=%B"],
            limit: 1_048_576,
            preempt: true
        )
        if output.truncated {
            throw GitFailure(message: String(localized: "The latest commit message is too long to edit."))
        }
        try requireOK(output, fallback: String(localized: "Couldn't read the latest commit message."))
        return String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func log(skip: Int, limit: Int) async throws -> LogPage {
        try await commitPage(key: "log", skip: skip, limit: limit, path: nil)
    }

    func fileLog(path: String, skip: Int, limit: Int) async throws -> LogPage {
        try await commitPage(key: "filelog", skip: skip, limit: limit, path: path)
    }

    func files(in oid: String) async throws -> CappedList<PathStatus> {
        let output = try await capture(
            key: "commit-files",
            args: ["diff-tree", "--find-renames", "--root", "--no-commit-id", "--name-status", "-r", "-z", oid],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the changed files."))
        let files = await Self.parse(output.stdout) { GitPathStatusParser.parse($0) }
        return CappedList(values: files, capped: output.truncated)
    }

    /// `base...head` で変わったファイル。head 側に無い base の変更は含めない。
    func files(from base: String, to head: String) async throws -> CappedList<PathStatus> {
        let output = try await capture(
            key: "commit-files",
            args: ["diff", "--find-renames", "--name-status", "-z", "\(base)...\(head)"],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the changed files."))
        let files = await Self.parse(output.stdout) { GitPathStatusParser.parse($0) }
        return CappedList(values: files, capped: output.truncated)
    }

    func branches() async throws -> [Branch] {
        let output = try await capture(
            key: "branches",
            args: ["for-each-ref", "refs/heads", "--format=%(refname:short)\t%(objectname)\t%(HEAD)\t%(upstream:short)\t%(upstream:remotename)"],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the branches."))
        return await Self.parse(output.stdout) { GitBranchParser.parse($0) }
    }

    func switchBranch(_ name: String) async throws {
        try await withWrite {
            let output = try await self.capture(key: "switch", args: ["switch", "--", name], limit: 65_536, preempt: false)
            try self.requireOK(output, fallback: String(localized: "Couldn't switch branches."))
        }
    }

    func deleteBranch(_ name: String) async throws {
        try await withWrite {
            let output = try await self.capture(
                key: "branch-delete",
                args: ["branch", "-D", "--", name],
                limit: 65_536,
                preempt: false
            )
            try self.requireOK(output, fallback: String(localized: "Couldn't delete the branch."))
        }
    }

    func renameBranch(_ name: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else {
            throw GitFailure(message: String(localized: "Enter a branch name."))
        }
        try await withWrite {
            let output = try await self.capture(
                key: "branch-rename",
                args: ["branch", "-m", "--", name, trimmed],
                limit: 65_536,
                preempt: false
            )
            try self.requireOK(output, fallback: String(localized: "Couldn't rename the branch."))
        }
    }

    /// 上流を取得してから、そのブランチを上流の上にリベースする。
    func rebase(branch: String, onto upstream: String, remote: String?) async throws {
        try await withWrite {
            if let remote, !remote.isEmpty {
                try await self.fetch(remote)
            }
            let output = try await self.capture(
                key: "rebase",
                args: ["rebase", upstream, branch],
                limit: 262_144,
                preempt: false
            )
            try self.requireOK(output, fallback: String(localized: "Couldn't rebase the branch."))
        }
    }

    /// 上流を取得し、ブランチをその先端に合わせる。チェックアウト中は作業ツリーも捨てる。
    func matchRemote(branch: String, upstream: String, remote: String, isCurrent: Bool) async throws {
        try await withWrite {
            try await self.fetch(remote)
            if isCurrent {
                let output = try await self.capture(
                    key: "reset",
                    args: ["reset", "--hard", upstream],
                    limit: 65_536,
                    preempt: false
                )
                try self.requireOK(output, fallback: String(localized: "Couldn't reset the branch."))
            } else {
                let output = try await self.capture(
                    key: "branch-force",
                    args: ["branch", "-f", "--", branch, upstream],
                    limit: 65_536,
                    preempt: false
                )
                try self.requireOK(output, fallback: String(localized: "Couldn't reset the branch."))
            }
        }
    }

    /// ブランチをリモートへ送る。履歴が分かれているときは、確認のあと `forceWithLease` で置き換える。
    func push(remote: String, branch: String, forceWithLease: Bool, setUpstream: Bool) async throws {
        var args = ["push"]
        if setUpstream { args.append("-u") }
        if forceWithLease { args.append("--force-with-lease") }
        args.append(contentsOf: [remote, branch])
        try await withWrite {
            let output = try await self.capture(
                key: "push",
                args: args,
                limit: 262_144,
                preempt: false
            )
            try self.requireOK(output, fallback: String(localized: "Couldn't push."))
        }
    }

    /// `branch` にしかないコミットと、`upstream` にしかないコミットの数で分ける。
    func pushDivergence(branch: String, upstream: String) async throws -> PushDivergence {
        let output = try await capture(
            key: "push-check",
            args: ["rev-list", "--left-right", "--count", "\(branch)...\(upstream)"],
            limit: 256,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't compare with the remote branch."))
        let fields = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let ahead = Int(fields[0]), let behind = Int(fields[1]) else {
            throw GitFailure(message: String(localized: "Couldn't compare with the remote branch."))
        }
        if ahead > 0, behind > 0 { return .diverged }
        if behind > 0 { return .behind }
        if ahead > 0 { return .fastForward }
        return .upToDate
    }

    /// 追跡中のリモート、なければ origin、それもなければ最初のリモート。
    func remoteLink(preferredRemote: String?) async throws -> RemoteLink? {
        let listed = try await capture(
            key: "remote-url",
            args: ["remote"],
            limit: 4096,
            preempt: true
        )
        try requireOK(listed, fallback: String(localized: "Couldn't read the remote."))
        let names = String(decoding: listed.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.isEmpty }
        let chosen = preferredRemote.flatMap { names.contains($0) ? $0 : nil }
            ?? names.first { $0 == "origin" }
            ?? names.first
        guard let chosen else { return nil }
        let url = try await capture(
            key: "remote-url",
            args: ["remote", "get-url", chosen],
            limit: 4096,
            preempt: true
        )
        try requireOK(url, fallback: String(localized: "Couldn't read the remote."))
        let text = String(decoding: url.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteLink(name: chosen, browserURL: RemoteBrowserURL.page(from: text))
    }

    private func fetch(_ remote: String) async throws {
        let output = try await capture(
            key: "fetch",
            args: ["fetch", "--prune", remote],
            limit: 262_144,
            preempt: false
        )
        try requireOK(output, fallback: String(localized: "Couldn't fetch from the remote."))
    }

    func detach(oid: String) async throws {
        try await withWrite {
            let output = try await self.capture(
                key: "switch",
                args: ["switch", "--detach", "--", oid],
                limit: 65_536,
                preempt: false
            )
            try self.requireOK(output, fallback: String(localized: "Couldn't check out the commit."))
        }
    }

    func stashes() async throws -> [StashEntry] {
        let output = try await capture(
            key: "stash",
            args: ["stash", "list", "--pretty=format:%gd%x1f%H%x1f%gs%x1e"],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the stashes."))
        return await Self.parse(output.stdout) { GitStashParser.parse($0) }
    }

    func stashPush(message: String?, includeUntracked: Bool = false) async throws {
        var args = ["stash", "push"]
        if includeUntracked {
            args.append("-u")
        }
        if let message, !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        try await withWrite {
            let output = try await self.capture(key: "stash-write", args: args, limit: 65_536, preempt: false)
            try self.requireOK(output, fallback: String(localized: "Couldn't create the stash."))
        }
    }

    /// 渡したパスのうち、gitignore に当てはまるものだけを返す。追跡済みファイルは含めない。
    /// 終了コード 1 は「どれも無視されない」なので失敗にしない。
    func ignored(among relativePaths: [String]) async throws -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }
        var input = Data()
        for path in relativePaths {
            input.append(contentsOf: Data(path.utf8))
            input.append(0)
        }
        let output = try await capture(
            key: "check-ignore",
            args: ["check-ignore", "-z", "--stdin"],
            input: input,
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        if output.status > 1 {
            try requireOK(output, fallback: String(localized: "Couldn't check ignored paths."))
        }
        return Set(Self.nulSeparated(output.stdout))
    }

    private static func nulSeparated(_ data: Data) -> [String] {
        var values: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            if index > start {
                values.append(String(decoding: data[start..<index], as: UTF8.self))
            }
            start = data.index(after: index)
        }
        if start < data.endIndex {
            values.append(String(decoding: data[start..<data.endIndex], as: UTF8.self))
        }
        return values
    }

    func stashApply(_ ref: String) async throws {
        try await stashCommand(["stash", "apply", "--", ref], fallback: String(localized: "Couldn't apply the stash."))
    }

    func stashPop(_ ref: String) async throws {
        try await stashCommand(["stash", "pop", "--", ref], fallback: String(localized: "Couldn't pop the stash."))
    }

    func stashDrop(_ ref: String) async throws {
        try await stashCommand(["stash", "drop", "--", ref], fallback: String(localized: "Couldn't drop the stash."))
    }

    func stashFiles(_ ref: String) async throws -> CappedList<PathStatus> {
        let output = try await capture(
            key: "stash",
            args: ["stash", "show", "--include-untracked", "--find-renames", "--name-status", "-z", ref],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the changed files."))
        let files = await Self.parse(output.stdout) { GitPathStatusParser.parse($0) }
        return CappedList(values: files, capped: output.truncated)
    }

    /// 追跡された変更は最初の親との差分。未追跡ファイルは3番目の親にだけ入っている。
    func stashFileDiff(ref: String, path: String, originalPath: String? = nil, ignoringWhitespace: Bool = false) async throws -> DiffDocument {
        var args = ["diff", "--find-renames", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        args.append(contentsOf: ["\(ref)^1", ref, "--"])
        if let originalPath, originalPath != path {
            args.append(originalPath)
        }
        args.append(path)
        let tracked = try await diffOutput(key: "diff", args: args)
        if !tracked.isEmpty || tracked.binary || tracked.truncated {
            let oldPath = originalPath ?? tracked.renameFrom ?? path
            return try await addingObjectImages(
                tracked,
                beforeRev: "\(ref)^1",
                beforePath: oldPath,
                afterRev: ref,
                afterPath: path
            )
        }
        if let untracked = try await untrackedStashDiff(ref: ref, path: path, ignoringWhitespace: ignoringWhitespace),
           !untracked.isEmpty || untracked.binary || untracked.truncated {
            return untracked
        }
        return tracked
    }

    private func untrackedStashDiff(ref: String, path: String, ignoringWhitespace: Bool) async throws -> DiffDocument? {
        var args = ["show", "--format=", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        args.append(contentsOf: ["\(ref)^3", "--", path])
        let output = try await capture(
            key: "diff",
            args: args,
            limit: GitLimits.diffByteLimit,
            preempt: true
        )
        if output.status != 0 { return nil }
        if output.truncated { return .tooLarge }
        let document = await Self.parse(output.stdout) { GitDiffParser.parse($0) }
        return try await addingObjectImages(
            document,
            beforeRev: nil,
            beforePath: path,
            afterRev: "\(ref)^3",
            afterPath: path
        )
    }

    func file(at rev: String, path: String) async throws -> FileBlob {
        let spec = "\(rev):\(path)"
        let image = ImagePaths.isImage(path)
        let limit = image ? GitLimits.imageByteLimit : GitLimits.fileByteLimit
        let sizeOutput = try await capture(key: "blob", args: ["cat-file", "-s", spec], limit: 64, preempt: true)
        try requireOK(sizeOutput, fallback: String(localized: "Couldn't read the file size."))
        let sizeText = String(decoding: sizeOutput.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = Int(sizeText) ?? 0
        if byteCount > limit {
            return FileBlob(byteCount: byteCount, truncated: true, binary: false, text: "")
        }
        let output = try await capture(
            key: "blob",
            args: ["show", "--no-ext-diff", "--no-color", spec],
            limit: limit + 1,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the file."))
        if output.truncated || output.stdout.count > limit {
            return FileBlob(byteCount: max(byteCount, output.stdout.count), truncated: true, binary: false, text: "")
        }
        if image {
            return FileBlob(byteCount: output.stdout.count, truncated: false, binary: true, text: "", image: output.stdout)
        }
        if output.stdout.contains(0) {
            return FileBlob(byteCount: output.stdout.count, truncated: false, binary: true, text: "")
        }
        return FileBlob(
            byteCount: output.stdout.count,
            truncated: false,
            binary: false,
            text: String(decoding: output.stdout, as: UTF8.self)
        )
    }

    func fileParentDiff(rev: String, path: String, ignoringWhitespace: Bool = false) async throws -> DiffDocument {
        try await showFileDiff(oid: rev, path: path, ignoringWhitespace: ignoringWhitespace)
    }

    func searchCommits(query: String) async throws -> CappedList<CommitRecord> {
        let output = try await capture(
            key: "search",
            args: [
                "log", "--branches", "--remotes", "--tags", "--date-order",
                "-n", "\(GitLimits.searchLimit + 1)", "-F", "-i", "--grep", query,
                "--pretty=format:\(Self.logFormat)", "--decorate=full"
            ],
            limit: GitLimits.listByteLimit,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't search commits."))
        let commits = await Self.parse(output.stdout) { GitLogParser.parse($0) }
        let capped = commits.count > GitLimits.searchLimit
        return CappedList(values: Array(commits.prefix(GitLimits.searchLimit)), capped: capped)
    }

    func searchPaths(query: String) async throws -> CappedList<String> {
        let scan = PathQueryScan(needle: query, limit: GitLimits.searchLimit)
        let output = try await capture(key: "search", args: ["ls-files", "-z"], limit: nil, preempt: true, scan: scan)
        try requireOK(output, fallback: String(localized: "Couldn't search paths."))
        let values = scan.snapshot()
        return CappedList(values: values, capped: scan.hitLimit)
    }

    func searchContent(query: String) async throws -> CappedList<ContentHit> {
        let scan = GrepScan(limit: GitLimits.searchLimit)
        let output = try await capture(
            key: "search",
            args: ["grep", "-n", "-I", "-i", "-F", "-e", query, "--", "."],
            limit: nil,
            preempt: true,
            scan: scan
        )
        if output.status != 0 && output.status != 1 {
            throw GitFailure(message: Self.failureText(output, fallback: String(localized: "Couldn't search file contents.")))
        }
        return CappedList(values: scan.snapshot(), capped: scan.hitLimit)
    }

    private static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%d%x1f%s%x1e"

    /// 未追跡ファイルは `git diff` が空になる。インデックスに無いときだけ `/dev/null` との差分を作る。
    private func untrackedWorktreeDiff(path: String, ignoringWhitespace: Bool) async throws -> DiffDocument? {
        let indexed = try await capture(
            key: "untracked-diff",
            args: ["cat-file", "-e", ":\(path)"],
            limit: 64,
            preempt: true
        )
        if indexed.status == 0 { return nil }
        var args = ["diff", "--no-index", "--no-ext-diff", "--no-color", "-U3"]
        if ignoringWhitespace { args.append("--ignore-all-space") }
        args.append(contentsOf: ["--", "/dev/null", path])
        let output = try await capture(
            key: "untracked-diff",
            args: args,
            limit: GitLimits.diffByteLimit,
            preempt: true
        )
        if output.truncated { return .tooLarge }
        if output.stdout.isEmpty || (output.status != 0 && output.status != 1) { return nil }
        return await Self.parse(output.stdout) { GitDiffParser.parse($0) }
    }

    /// 作業ツリーの差分。ステージ済みは HEAD とインデックス、未ステージはインデックスと作業ツリー。
    private func addingWorktreeImages(
        _ document: DiffDocument,
        path: String,
        originalPath: String?,
        staged: Bool
    ) async throws -> DiffDocument {
        guard !document.truncated else { return document }
        let oldName = originalPath ?? document.renameFrom
        guard ImagePaths.isImage(path) || ImagePaths.isImage(oldName ?? "") else { return document }
        if document.isEmpty, !staged {
            // 未追跡の画像は git diff が空になる。インデックスに無く、作業ツリーにあるときだけ絵を出す。
            let indexed = try await objectImage(rev: "", path: path)
            guard indexed == .absent else { return document }
            let after = worktreeImage(path)
            guard after != .absent else { return document }
            return replacingImages(
                DiffDocument(binary: true, truncated: false, header: "", hunks: [], renameFrom: nil, renameTo: nil),
                before: .absent,
                after: after
            )
        }
        guard !document.isEmpty else { return document }
        let before: ImagePayload
        let after: ImagePayload
        if staged {
            before = try await objectImage(rev: "HEAD", path: oldName ?? path)
            after = try await objectImage(rev: "", path: path)
        } else {
            before = try await indexImage(path: path, fallbackPath: oldName)
            after = worktreeImage(path)
        }
        return replacingImages(document, before: before, after: after)
    }

    private func mergeBase(_ base: String, _ head: String) async throws -> String {
        let output = try await capture(
            key: "merge-base",
            args: ["merge-base", "--", base, head],
            limit: 128,
            preempt: true
        )
        try requireOK(output, fallback: String(localized: "Couldn't read the diff."))
        let oid = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else {
            throw GitFailure(message: String(localized: "Couldn't read the diff."))
        }
        return oid
    }

    private func addingCommitImages(
        _ document: DiffDocument,
        oid: String,
        path: String,
        originalPath: String?
    ) async throws -> DiffDocument {
        let oldPath = originalPath ?? document.renameFrom ?? path
        return try await addingObjectImages(
            document,
            beforeRev: "\(oid)^",
            beforePath: oldPath,
            afterRev: oid,
            afterPath: path
        )
    }

    /// 両方のリビジョンが画像のときだけバイト列を足す。無い側は追加や削除として空のままにする。
    private func addingObjectImages(
        _ document: DiffDocument,
        beforeRev: String?,
        beforePath: String,
        afterRev: String?,
        afterPath: String
    ) async throws -> DiffDocument {
        guard !document.truncated else { return document }
        guard ImagePaths.isImage(beforePath) || ImagePaths.isImage(afterPath) else { return document }
        guard !document.isEmpty else { return document }
        let before = try await objectImage(rev: beforeRev, path: beforePath)
        let after = try await objectImage(rev: afterRev, path: afterPath)
        guard before != .absent || after != .absent else { return document }
        return replacingImages(document, before: before, after: after)
    }

    private func replacingImages(_ document: DiffDocument, before: ImagePayload, after: ImagePayload) -> DiffDocument {
        var copy = document
        copy.beforeImage = before
        copy.afterImage = after
        return copy
    }

    /// インデックス。リネームがまだステージされていないときは旧パスを見る。
    private func indexImage(path: String, fallbackPath: String?) async throws -> ImagePayload {
        let primary = try await objectImage(rev: "", path: path)
        if primary != .absent { return primary }
        if let fallbackPath, fallbackPath != path {
            return try await objectImage(rev: "", path: fallbackPath)
        }
        return .absent
    }

    private func objectImage(rev: String?, path: String) async throws -> ImagePayload {
        guard let rev else { return .absent }
        let spec = rev.isEmpty ? ":\(path)" : "\(rev):\(path)"
        let output = try await capture(
            key: "image",
            args: ["cat-file", "blob", spec],
            limit: GitLimits.imageByteLimit + 1,
            preempt: false
        )
        if output.status != 0 { return .absent }
        if output.truncated || output.stdout.count > GitLimits.imageByteLimit {
            return .tooLarge
        }
        return .data(output.stdout)
    }

    private func worktreeImage(_ path: String) -> ImagePayload {
        let root = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        let url = root.appending(path: path).standardizedFileURL
        let rootPath = root.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .absent }
        if data.count > GitLimits.imageByteLimit { return .tooLarge }
        return .data(data)
    }

    private func diffOutput(key: String, args: [String]) async throws -> DiffDocument {
        let output = try await capture(key: key, args: args, limit: GitLimits.diffByteLimit, preempt: true)
        if output.truncated {
            return .tooLarge
        }
        try requireOK(output, fallback: String(localized: "Couldn't read the diff."))
        return await Self.parse(output.stdout) { GitDiffParser.parse($0) }
    }

    private func commitPage(key: String, skip: Int, limit: Int, path: String?) async throws -> LogPage {
        let head = try await capture(key: key, args: ["rev-parse", "--verify", "--quiet", "HEAD"], limit: 128, preempt: true)
        if head.status != 0 {
            return LogPage(commits: [], hasMore: false)
        }
        let requested = max(1, limit)
        var args = [
            "log", "--date-order", "-n", "\(requested + 1)", "--skip", "\(max(0, skip))",
            "--pretty=format:\(Self.logFormat)", "--decorate=full"
        ]
        if let path {
            args.append(contentsOf: ["--follow", "--", path])
        } else {
            args.append(contentsOf: ["--branches", "--remotes", "--tags"])
        }
        let output = try await capture(key: key, args: args, limit: 8_000_000, preempt: true)
        try requireOK(output, fallback: String(localized: "Couldn't read the history."))
        let commits = await Self.parse(output.stdout) { GitLogParser.parse($0) }
        let hasMore = commits.count > requested
        return LogPage(commits: hasMore ? Array(commits.prefix(requested)) : commits, hasMore: hasMore)
    }

    private func stashCommand(_ args: [String], fallback: String) async throws {
        try await withWrite {
            let output = try await self.capture(key: "stash-write", args: args, limit: 65_536, preempt: false)
            try self.requireOK(output, fallback: fallback)
        }
    }

    private func mutate(paths: [String], fallback: String, args: ([String]) -> [String]) async throws {
        try await withWrite {
            try await self.mutateUnlocked(paths: paths, fallback: fallback, args: args)
        }
    }

    private func mutateUnlocked(paths: [String], fallback: String, args: ([String]) -> [String]) async throws {
        for chunk in chunked(paths, size: 80) {
            let output = try await capture(key: "write-\(UUID().uuidString)", args: args(chunk), limit: 65_536, preempt: false)
            try requireOK(output, fallback: fallback)
        }
    }

    private func capture(
        key: String,
        args: [String],
        input: Data? = nil,
        limit: Int?,
        preempt: Bool,
        scan: GitStdoutScan? = nil
    ) async throws -> GitOutput {
        let box = GitProcessBox()
        if preempt {
            let previous = inflight[key]
            inflight[key] = box
            previous?.terminate()
        }
        do {
            let output = try await box.run(
                Self.makeRequest(repo: workingDirectory, args: args, input: input, limit: limit, scan: scan),
                cancelOnTaskCancel: preempt
            )
            if preempt, inflight[key] === box {
                inflight[key] = nil
            }
            return output
        } catch {
            if preempt, inflight[key] === box {
                inflight[key] = nil
            }
            throw error
        }
    }

    private func requireOK(_ output: GitOutput, fallback: String) throws {
        if output.status == 0 { return }
        throw GitFailure(message: Self.failureText(output, fallback: fallback))
    }

    private static func failureText(_ output: GitOutput, fallback: String) -> String {
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return String(localized: "\(fallback) (exit code \(Int(output.status)))")
    }

    private static func parse<T: Sendable>(_ data: Data, _ body: @Sendable @escaping (Data) -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            body(data)
        }.value
    }

    private static func makeRequest(
        repo: String?,
        args: [String],
        input: Data? = nil,
        limit: Int? = nil,
        scan: GitStdoutScan? = nil
    ) -> GitRequest {
        var full = ["-c", "diff.renames=true", "-c", "core.quotepath=false"]
        if let repo {
            full.insert(contentsOf: ["-C", repo], at: 0)
        }
        full.append(contentsOf: args)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return GitRequest(
            arguments: full,
            environment: environment,
            workingDirectory: repo,
            standardInput: input,
            stdoutByteLimit: limit,
            scan: scan
        )
    }

    private func withWrite<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquireWrite()
        do {
            let value = try await body()
            releaseWrite()
            return value
        } catch {
            releaseWrite()
            throw error
        }
    }

    private func acquireWrite() async {
        if !writeLocked {
            writeLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    private func releaseWrite() {
        if writeWaiters.isEmpty {
            writeLocked = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    private func chunked(_ items: [String], size: Int) -> [[String]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start..<min(start + size, items.count)])
        }
    }
}

private extension Process {
    /// `Process.terminate()` raises when the task has already exited.
    nonisolated func stop() {
        guard isRunning else { return }
        kill(processIdentifier, SIGTERM)
    }
}

nonisolated struct GitRequest: Sendable {
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var standardInput: Data?
    var stdoutByteLimit: Int?
    var scan: GitStdoutScan?
}

nonisolated protocol GitStdoutScan: AnyObject, Sendable {
    func accept(_ chunk: Data) -> Bool
}

nonisolated final class PathQueryScan: GitStdoutScan, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var matches: [String] = []
    private let needle: String
    private let limit: Int
    private(set) var hitLimit = false

    init(needle: String, limit: Int) {
        self.needle = needle
        self.limit = limit
    }

    func accept(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        while let nul = pending.firstIndex(of: 0) {
            let piece = pending.prefix(upTo: nul)
            pending.removeSubrange(pending.startIndex...nul)
            guard matches.count < limit else {
                hitLimit = true
                continue
            }
            let path = String(decoding: piece, as: UTF8.self)
            if path.localizedStandardContains(needle) {
                matches.append(path)
                if matches.count >= limit {
                    hitLimit = true
                }
            }
        }
        return false
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return matches
    }
}

nonisolated final class GrepScan: GitStdoutScan, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var matches: [ContentHit] = []
    private let limit: Int
    private(set) var hitLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func accept(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let piece = pending.prefix(upTo: newline)
            pending.removeSubrange(pending.startIndex...newline)
            if matches.count >= limit {
                hitLimit = true
                return true
            }
            let line = String(decoding: piece, as: UTF8.self)
            if let hit = GitGrepParser.parseLine(line) {
                matches.append(hit)
            }
            if matches.count >= limit {
                hitLimit = true
                return true
            }
        }
        return false
    }

    func snapshot() -> [ContentHit] {
        lock.lock()
        defer { lock.unlock() }
        return matches
    }
}

nonisolated final class GitProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private static let ioQueue = DispatchQueue(label: "work.idyl.GitSprout.git-io", qos: .userInitiated, attributes: .concurrent)

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.stop()
    }

    func run(_ request: GitRequest, cancelOnTaskCancel: Bool) async throws -> GitOutput {
        if cancelOnTaskCancel {
            return try await withTaskCancellationHandler {
                try await self.runOnBackground(request)
            } onCancel: {
                self.terminate()
            }
        }
        return try await runOnBackground(request)
    }

    private func runOnBackground(_ request: GitRequest) async throws -> GitOutput {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    continuation.resume(returning: try self.execute(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute(_ request: GitRequest) throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = request.arguments
        process.environment = request.environment
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.qualityOfService = .userInitiated

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        lock.lock()
        if cancelled {
            lock.unlock()
            throw GitCancelled()
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            throw GitFailure(message: String(localized: "Couldn't start git."))
        }

        lock.lock()
        let killNow = cancelled
        lock.unlock()
        if killNow {
            process.stop()
        }

        let state = IOState()
        let group = DispatchGroup()
        group.enter()
        Self.ioQueue.async {
            state.readStdout(
                handle: outPipe.fileHandleForReading,
                process: process,
                limit: request.stdoutByteLimit,
                scan: request.scan
            )
            group.leave()
        }
        group.enter()
        Self.ioQueue.async {
            state.readStderr(handle: errPipe.fileHandleForReading)
            group.leave()
        }
        group.enter()
        Self.ioQueue.async {
            do {
                if let input = request.standardInput {
                    try inPipe.fileHandleForWriting.write(contentsOf: input)
                }
                try inPipe.fileHandleForWriting.close()
            } catch {
                try? inPipe.fileHandleForWriting.close()
            }
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        let snapshot = state.snapshot()

        if snapshot.stoppedEarly {
            return GitOutput(status: 0, stdout: snapshot.stdout, stderr: snapshot.stderr, truncated: false)
        }
        if process.terminationReason == .uncaughtSignal {
            if snapshot.truncated {
                return GitOutput(status: process.terminationStatus, stdout: snapshot.stdout, stderr: snapshot.stderr, truncated: true)
            }
            throw GitCancelled()
        }
        return GitOutput(
            status: process.terminationStatus,
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            truncated: snapshot.truncated
        )
    }
}

private nonisolated final class IOState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false
    private var stoppedEarly = false

    func readStdout(handle: FileHandle, process: Process, limit: Int?, scan: GitStdoutScan?) {
        var stored = Data()
        var didTruncate = false
        var didStop = false
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 65_536) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            if let scan {
                if scan.accept(chunk) {
                    didStop = true
                    process.stop()
                    drain(handle)
                    break
                }
                continue
            }
            if let limit {
                if stored.count >= limit {
                    didTruncate = true
                    process.stop()
                    drain(handle)
                    break
                }
                let room = limit - stored.count
                if chunk.count > room {
                    stored.append(chunk.prefix(room))
                    didTruncate = true
                    process.stop()
                    drain(handle)
                    break
                }
            }
            stored.append(chunk)
        }
        lock.lock()
        stdout = stored
        truncated = didTruncate
        stoppedEarly = didStop
        lock.unlock()
    }

    func readStderr(handle: FileHandle) {
        var stored = Data()
        let limit = 65_536
        while stored.count < limit {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 16_384) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            let room = limit - stored.count
            if chunk.count > room {
                stored.append(chunk.prefix(room))
                drain(handle)
                break
            }
            stored.append(chunk)
        }
        lock.lock()
        stderr = stored
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: String, truncated: Bool, stoppedEarly: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, String(decoding: stderr, as: UTF8.self), truncated, stoppedEarly)
    }

    private func drain(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {}
    }
}
