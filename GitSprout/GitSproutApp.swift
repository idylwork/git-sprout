//
//  GitSproutApp.swift
//  GitSprout
//

import AppKit
import SwiftUI

@main
struct GitSproutApp: App {
    @NSApplicationDelegateAdaptor(GitSproutAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppSettings.appearanceKey) private var appearanceRaw = AppSettings.Appearance.system.rawValue

    init() {
        AppSettings.register()
    }

    var body: some Scene {
        // `WindowGroup` は `open` やフォルダを開くたびにウィンドウを増やす。状態は一つのので、ウィンドウも一つにする。
        Window("GitSprout", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(colorScheme)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    model.openExternal(urls: [url])
                }
                .onAppear {
                    appDelegate.bind(model)
                    model.reopenLastRepositoryIfNeeded()
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    model.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Clear Recent Repositories") {
                    model.clearRecent()
                }
                .disabled(model.recent.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload") {
                    Task { await model.session?.refreshActive() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.session == nil)
                Button("Terminal") {
                    model.session?.terminalVisible.toggle()
                }
                .disabled(model.session == nil)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        AppSettings.Appearance(rawValue: appearanceRaw)?.colorScheme
    }
}

@MainActor
final class GitSproutAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var pending: [URL] = []
    private var menuObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var shortcutScheduled = false

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleTerminalShortcut()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isCommandAt(event) else { return event }
            self.toggleTerminal()
            return nil
        }
        scheduleTerminalShortcut()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleTerminalShortcut()
    }

    /// Dock や `open` で前面に戻したときは、見えている窓をそのまま使う。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return false }
        if let window = mainWindow(in: sender) {
            orderFront(window)
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        deliver([URL(fileURLWithPath: filename)])
        return true
    }

    @objc nonisolated func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let urls = OpenDocumentEvent.urls(from: event)
        Task { @MainActor in
            self.deliver(urls)
        }
    }

    func bind(_ model: AppModel) {
        self.model = model
        guard !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        model.openExternal(urls: queued)
    }

    /// SwiftUI の `keyboardShortcut("@")` は US 配列の Shift+2 になる。JIS の ⌘@ をメニューへ直接付ける。
    private func scheduleTerminalShortcut() {
        guard !shortcutScheduled else { return }
        shortcutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.shortcutScheduled = false
            self?.applyTerminalShortcut()
        }
    }

    private func applyTerminalShortcut() {
        let titles: Set<String> = [String(localized: "Terminal"), "Terminal", "ターミナル"]
        guard let item = NSApp.mainMenu.flatMap({ menuItem(in: $0, titles: titles) }) else { return }
        let flags = item.keyEquivalentModifierMask
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if item.keyEquivalent == "@", flags == .command, !item.allowsAutomaticKeyEquivalentLocalization {
            return
        }
        item.allowsAutomaticKeyEquivalentLocalization = false
        item.keyEquivalent = "@"
        item.keyEquivalentModifierMask = .command
    }

    private func menuItem(in menu: NSMenu, titles: Set<String>) -> NSMenuItem? {
        for item in menu.items {
            if titles.contains(item.title) { return item }
            if let submenu = item.submenu, let found = menuItem(in: submenu, titles: titles) {
                return found
            }
        }
        return nil
    }

    private func isCommandAt(_ event: NSEvent) -> Bool {
        if event.isARepeat { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags == .command else { return false }
        return event.charactersIgnoringModifiers == "@"
    }

    private func toggleTerminal() {
        model?.session?.terminalVisible.toggle()
    }

    private func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let window = mainWindow(in: NSApp) {
            orderFront(window)
        }
        if let model {
            model.openExternal(urls: urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    private func mainWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { $0.canBecomeMain && !$0.isKind(of: NSPanel.self) }
    }

    private func orderFront(_ window: NSWindow) {
        NSApp.activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

nonisolated enum OpenDocumentEvent {
    static func urls(from event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        if direct.descriptorType == typeAEList {
            let count = direct.numberOfItems
            guard count > 0 else { return [] }
            return (1...count).compactMap { index in
                direct.atIndex(index).flatMap(fileURL(from:))
            }
        }
        return fileURL(from: direct).map { [$0] } ?? []
    }

    private static func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        let candidates = [descriptor.coerce(toDescriptorType: typeFileURL), descriptor].compactMap { $0 }
        for source in candidates {
            let bytes = source.data.filter { $0 != 0 }
            if let text = String(data: bytes, encoding: .utf8),
               let url = URL(string: text), url.isFileURL {
                return url
            }
            if let text = source.stringValue?.trimmingCharacters(in: .controlCharacters),
               let url = URL(string: text), url.isFileURL {
                return url
            }
        }
        return nil
    }
}
