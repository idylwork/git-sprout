import CoreServices
import Foundation

/// 作業ツリーと `.git` の変更を、前面にいるあいだだけまとめて知らせる。
final class RepoWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var generation = 0
    private var stopped = true
    private var root = ""
    private var onFlush: (@MainActor (RepoChange) async -> Void)?
    private var refsChanged = false
    private var worktree: [String] = []
    private var worktreeOverflow = false
    private var debounce: Task<Void, Never>?

    func start(root: String, onFlush: @escaping @MainActor (RepoChange) async -> Void) {
        stop()
        let standardized = URL(fileURLWithPath: root).standardizedFileURL.path(percentEncoded: false)
        lock.lock()
        generation += 1
        stopped = false
        self.root = standardized
        self.onFlush = onFlush
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        )
        guard let created = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [standardized] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }
        lock.lock()
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
    }

    func stop() {
        lock.lock()
        generation += 1
        let token = generation
        stopped = true
        let current = stream
        stream = nil
        lock.unlock()
        if let current {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
        Task { @MainActor in
            guard self.isCurrent(token) else { return }
            self.debounce?.cancel()
            self.debounce = nil
            self.refsChanged = false
            self.worktree.removeAll()
            self.worktreeOverflow = false
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    fileprivate func accept(_ paths: [String]) {
        lock.lock()
        let inactive = stopped
        let root = self.root
        lock.unlock()
        guard !inactive, !root.isEmpty else { return }
        let change = RepoChange.classify(absolutePaths: paths, root: root)
        guard change.refsChanged || !change.worktreePaths.isEmpty else { return }
        Task { @MainActor in
            guard !self.isStopped() else { return }
            if change.refsChanged {
                self.refsChanged = true
            }
            if self.worktree.count + change.worktreePaths.count > RepoChange.worktreeCap {
                self.worktreeOverflow = true
                self.worktree.removeAll()
            } else if !self.worktreeOverflow {
                self.worktree.append(contentsOf: change.worktreePaths)
            }
            self.scheduleFlush()
        }
    }

    @MainActor
    private func scheduleFlush() {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let change = RepoChange(
                refsChanged: refsChanged,
                worktreePaths: Array(Set(worktree)),
                worktreeOverflow: worktreeOverflow
            )
            refsChanged = false
            worktree.removeAll()
            worktreeOverflow = false
            guard change.refsChanged || change.worktreeOverflow || !change.worktreePaths.isEmpty else { return }
            await onFlush?(change)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
        guard let info, numEvents > 0 else { return }
        let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
        let listed = unsafeBitCast(eventPaths, to: NSArray.self)
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for index in 0..<numEvents {
            if let path = listed[index] as? String {
                paths.append(path)
            }
        }
        watcher.accept(paths)
    }
}

struct RepoChange: Equatable, Sendable {
    var refsChanged: Bool
    var worktreePaths: [String]
    /// 作業ツリーのパスが多すぎて個別に持てない。status をそのまま読む。
    var worktreeOverflow: Bool

    static let ignoreProbeLimit = 32
    static let worktreeCap = 4_096

    static func classify(absolutePaths: [String], root: String) -> RepoChange {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var refsChanged = false
        var worktree: [String] = []
        var seen = Set<String>()
        for absolute in absolutePaths {
            let path = absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
            let relative: String
            if path == root {
                continue
            } else if path.hasPrefix(prefix) {
                relative = String(path.dropFirst(prefix.count))
            } else {
                continue
            }
            if relative == ".git" || relative.hasPrefix(".git/") {
                if isObjectStore(relative) { continue }
                if isGitMetadata(relative) {
                    refsChanged = true
                }
                continue
            }
            guard !relative.isEmpty, seen.insert(relative).inserted else { continue }
            worktree.append(relative)
        }
        return RepoChange(refsChanged: refsChanged, worktreePaths: worktree, worktreeOverflow: false)
    }

    private static func isObjectStore(_ relative: String) -> Bool {
        relative == ".git/objects" || relative.hasPrefix(".git/objects/")
    }

    private static func isGitMetadata(_ relative: String) -> Bool {
        if relative.hasSuffix(".lock") { return false }
        switch relative {
        case ".git", ".git/HEAD", ".git/ORIG_HEAD", ".git/FETCH_HEAD", ".git/index", ".git/packed-refs",
             ".git/MERGE_HEAD", ".git/CHERRY_PICK_HEAD", ".git/REVERT_HEAD", ".git/REBASE_HEAD":
            return true
        default:
            return relative.hasPrefix(".git/refs/")
                || relative.hasPrefix(".git/rebase-merge/")
                || relative.hasPrefix(".git/rebase-apply/")
        }
    }
}
