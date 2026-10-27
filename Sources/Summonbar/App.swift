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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Shell.loadUserEnvironment()
        TerminalLauncher.cleanUp()
        model = LauncherModel()
        panel = PanelController(model: model)
        model.runsChanged = { [weak self] in self?.updateStatusItem() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Summonbar")
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()
        registerHotKey()

        // open -a Summonbar --args --ask claude ~/Workspaces/foo "fix the build"
        // open -a Summonbar --args --query "new my-app"
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ask"), args.count > i + 3 {
            model.ask(agentId: args[i + 1], path: args[i + 2], prompt: args[i + 3])
            panel.show()
        } else if let i = args.firstIndex(of: "--query"), args.count > i + 1 {
            panel.show()
            model.query = args[i + 1]
        } else if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            panel.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
    }

    private func registerHotKey() {
        let spec = model.config.hotkey
        hotKey = HotKey(spec) { [weak self] in self?.panel.toggle() }
        if hotKey == nil {
            model.flash("Couldn't register hotkey \(spec) — change it in config.json")
            panel.show()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Summonbar  (\(HotKey.describe(model.config.hotkey)))", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Agent Runs", action: #selector(openRuns), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reload Config & Hotkey", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: ""))
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
        model.reload()
        model.refresh()
        hotKey = nil
        registerHotKey()
        rebuildMenu()
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(Config.fileURL)
    }
}
