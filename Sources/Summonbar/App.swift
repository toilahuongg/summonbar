import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: LauncherModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var appHotKeys: [HotKey] = []
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Shell.loadUserEnvironment()
        TerminalLauncher.cleanUp()
        model = LauncherModel()
        panel = PanelController(model: model)
        model.runsChanged = { [weak self] in self?.updateStatusItem() }
        model.openSettings = { [weak self] in self?.settings.show() }
        model.openApplicationSettings = { [weak self] app in
            guard let self else { return }
            settings.model.tab = .applications
            settings.model.appFilter = app.name
            settings.show()
        }
        settings.model.apply = { [weak self] in self?.applyConfig() }
        settings.model.installedApps = { [weak self] in self?.model.apps ?? [] }
        // Recording a shortcut must not trigger the one it's replacing.
        settings.model.pauseHotKey = { [weak self] paused in
            guard let self else { return }
            hotKey = nil
            appHotKeys = []
            if !paused {
                registerHotKey(report: false)
                registerAppHotKeys()
            }
        }
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Summonbar")
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()
        registerHotKey()
        registerAppHotKeys()

        // open -a Summonbar --args --ask claude ~/Workspaces/foo "fix the build"
        // open -a Summonbar --args --query "new my-app"
        // open -a Summonbar --args --settings
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ask"), args.count > i + 3 {
            model.ask(agentId: args[i + 1], path: args[i + 2], prompt: args[i + 3])
            panel.show()
        } else if let i = args.firstIndex(of: "--query"), args.count > i + 1 {
            panel.show()
            model.query = args[i + 1]
        } else if args.contains("--settings") {
            settings.show()
        } else if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            panel.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
    }

    @discardableResult
    private func registerHotKey(report: Bool = true) -> Bool {
        let spec = model.config.hotkey
        hotKey = HotKey(spec) { [weak self] in self?.panel.toggle() }
        if hotKey == nil && report {
            model.flash("Couldn't register hotkey \(spec) — change it in Settings (⌘,)")
            panel.show()
        }
        return hotKey != nil
    }

    /// Per-app hotkeys from config.json. Returns the ones that couldn't be registered.
    @discardableResult
    private func registerAppHotKeys() -> [String] {
        appHotKeys = []
        var failed: [String] = []
        for (key, spec) in (model.config.applications.hotkeys ?? [:]).sorted(by: { $0.key < $1.key }) where !spec.isEmpty {
            if let hotKey = HotKey(spec, handler: { [weak self] in self?.model.toggleApp(key: key) }) {
                appHotKeys.append(hotKey)
            } else {
                failed.append(HotKey.describe(spec))
            }
        }
        return failed
    }

    /// Re-reads config.json and applies it. Returns an error for the Settings window.
    private func applyConfig() -> String? {
        model.reload()
        model.refresh()
        hotKey = nil
        appHotKeys = []
        let ok = registerHotKey(report: false)
        let failed = (ok ? [] : [HotKey.describe(model.config.hotkey)]) + registerAppHotKeys()
        rebuildMenu()
        return failed.isEmpty ? nil : "Couldn't register \(failed.joined(separator: ", ")) — another app may be using it."
    }

    /// Accessory apps have no visible menu bar, but text fields still need the
    /// Edit menu's key equivalents (⌘C, ⌘V, ⌘Z …) and windows need ⌘W.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        appItem.submenu?.items.forEach { $0.target = self }
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Summonbar  (\(HotKey.describe(model.config.hotkey)))", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Agent Runs", action: #selector(openRuns), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Config & Hotkey", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Summonbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    private func updateStatusItem() {
        let running = model.runningCount
        statusItem.button?.title = running > 0 ? " \(running)" : ""
    }

    @objc private func openPanel() { panel.show() }

    @objc private func openRuns() {
        model.showRuns()
        panel.show()
    }

    @objc private func reloadConfig() {
        if let error = applyConfig() {
            model.flash(error)
            panel.show()
        }
    }

    @objc private func openSettings() {
        panel.hide()
        settings.show()
    }
}
