//
//  AppModel.swift
//  GitSprout
//

import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    var session: WorkspaceSession?
    var recent: [String] = []
    var openError: String?

    private static let recentKey = "recentRepositories"
    private var lastExternalOpen: (path: String, date: Date)?
    private var openGeneration = 0

    init() {
        AppSettings.register()
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a Git repository folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        let generation = beginOpen()
        Task { await open(path: path, generation: generation) }
    }

    func openExternal(urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        let path = RepositoryPath.containingDirectory(for: url.path(percentEncoded: false))
        let now = Date()
        if let lastExternalOpen, lastExternalOpen.path == path, now.timeIntervalSince(lastExternalOpen.date) < 1 {
            return
        }
        lastExternalOpen = (path, now)
        let generation = beginOpen()
        Task { await open(path: path, generation: generation) }
    }

    /// 起動時に、まだ何も開いていなければ最近の先頭を開く。
    func reopenLastRepositoryIfNeeded() {
        guard openGeneration == 0 else { return }
        guard AppSettings.reopenLastRepository, session == nil, let path = recent.first else { return }
        let generation = beginOpen()
        Task { await open(path: path, generation: generation) }
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func open(path: String, generation: Int? = nil) async {
        let generation = generation ?? beginOpen()
        let directory = RepositoryPath.containingDirectory(for: path)
        if directory == session?.rootPath { return }
        do {
            let root = try await GitClient.resolveRepository(at: directory)
            guard generation == openGeneration else { return }
            if root == session?.rootPath { return }
            session?.stopWatching()
            remember(root)
            session = WorkspaceSession(rootPath: root)
            openError = nil
        } catch is GitCancelled {
            return
        } catch {
            guard generation == openGeneration else { return }
            openError = (error as? GitFailure)?.message ?? error.localizedDescription
        }
    }

    private func beginOpen() -> Int {
        openGeneration += 1
        return openGeneration
    }

    private func remember(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 8 {
            recent.removeLast(recent.count - 8)
        }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
}

nonisolated enum RepositoryPath {
    static func containingDirectory(for path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let standardized = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else { return standardized }
        return url.deletingLastPathComponent().path(percentEncoded: false)
    }

    static func menuTitle(for path: String, among paths: [String]) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let duplicates = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == name }
        guard duplicates.count > 1 else { return name }
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty else { return name }
        return "\(name) — \(parent)"
    }
}
