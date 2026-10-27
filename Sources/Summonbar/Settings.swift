import AppKit
import ServiceManagement
import SwiftUI

/// Editable copy of config.json. Changes are written back (debounced) and
/// applied live through `apply`.
@MainActor
final class SettingsModel: ObservableObject {
    struct AgentRow: Identifiable {
        let id: String
        let name: String
        let icon: String
        let path: String?
        var enabled: Bool
        var args: String
        var headlessArgs: String
        /// Whether config.json already mentions this agent.
        let configured: Bool

        var installed: Bool { path != nil }
    }

    struct AppChoice: Hashable {
        let value: String
        let name: String
    }

    struct AppRow: Identifiable {
        let app: InstalledApp
        var alias: String
        var hotkey: String
        var visible: Bool

        var id: String { app.key }
    }

    enum Tab: Hashable { case general, agents, applications, shortcuts }

    @Published var workspacesRoot = "" { didSet { scheduleSave() } }
    @Published var hotkey = "" { didSet { scheduleSave() } }
    @Published var terminal = "" { didSet { scheduleSave() } }
    @Published var editor = "" { didSet { scheduleSave() } }
    @Published var defaultAgent = "" { didSet { scheduleSave() } }
    @Published var gitInitNewProjects = true { didSet { scheduleSave() } }
    @Published var checkForUpdates = true { didSet { scheduleSave() } }
    @Published var translateTo = "" { didSet { scheduleSave() } }
    /// "" turns the alternate off; nil keeps the default (the system language).
    @Published var translateAlternate: String? { didSet { scheduleSave() } }
    @Published var agents: [AgentRow] = [] { didSet { scheduleSave() } }
    @Published var appsInSearch = true { didSet { scheduleSave() } }
    @Published var appRows: [AppRow] = [] { didSet { scheduleSave() } }
    @Published var appFilter = ""
    @Published var tab = Tab.general
    @Published private(set) var launchAtLogin = false
    @Published private(set) var error: String?

    /// Reloads the app from config.json; returns an error to show, if any.
    var apply: () -> String? = { nil }
    var pauseHotKey: (Bool) -> Void = { _ in }
    /// Checks for an update, or installs the one already found.
    var updateSummonbar: () -> Void = {}
    /// The launcher's scan, so Settings doesn't walk the app folders again.
    var installedApps: () -> [InstalledApp] = { [] }

    private var loading = false
    private var saveWork: DispatchWorkItem?

    func load() {
        loading = true
        defer { loading = false }
        let config = Config.load()
        workspacesRoot = config.workspacesRoot.tildePath
        hotkey = config.hotkey
        terminal = config.terminal
        editor = config.editor
        defaultAgent = config.defaultAgent
        gitInitNewProjects = config.gitInitNewProjects
        checkForUpdates = config.checkForUpdates
        translateTo = config.translation.target
        translateAlternate = config.translation.alternate
        agents = AgentCatalog.specs.map { spec in
            let override = config.agents[spec.id]
            return AgentRow(id: spec.id, name: spec.name, icon: spec.icon, path: Shell.which(spec.binary),
                            enabled: override?.disabled != true,
                            args: Args.join(override?.args ?? []),
                            headlessArgs: Args.join(override?.headlessArgs ?? []),
                            configured: override != nil)
        }
        let settings = config.applications
        let installed = installedApps()
        appsInSearch = settings.isEnabled
        appRows = (installed.isEmpty ? AppScanner.scan(extraDirectories: settings.directoryURLs) : installed).map { app in
            AppRow(app: app, alias: settings.alias(app) ?? "", hotkey: settings.hotkey(app) ?? "", visible: !settings.isHidden(app))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        error = nil
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil

        var config = Config.load()
        let root = workspacesRoot.trimmingCharacters(in: .whitespaces)
        if !root.isEmpty {
            config.workspacesRoot = URL(fileURLWithPath: Config.expand(root), isDirectory: true)
        }
        config.hotkey = hotkey
        config.terminal = terminal
        config.editor = editor
        config.defaultAgent = defaultAgent
        config.gitInitNewProjects = gitInitNewProjects
        config.checkForUpdates = checkForUpdates
        config.translation.to = translateTo == "en" && config.translation.to == nil ? nil : translateTo
        config.translation.alternate = translateAlternate
        for row in agents {
            let args = Args.split(row.args), headless = Args.split(row.headlessArgs)
            // Keep config.json tidy: only write agents the user has touched.
            guard row.configured || !row.enabled || !args.isEmpty || !headless.isEmpty else { continue }
            var override = config.agents[row.id] ?? AgentOverride()
            override.args = args
            override.headlessArgs = headless
            override.disabled = row.enabled ? nil : true
            config.agents[row.id] = override
        }
        // Merge, so entries for apps that aren't installed right now are kept.
        var apps = config.applications
        var aliases = apps.aliases ?? [:], hotkeys = apps.hotkeys ?? [:]
        var hidden = Set(apps.hidden ?? [])
        for row in appRows {
            let alias = row.alias.trimmingCharacters(in: .whitespaces)
            aliases[row.id] = alias.isEmpty ? nil : alias
            hotkeys[row.id] = row.hotkey.isEmpty ? nil : row.hotkey
            if row.visible { hidden.remove(row.id) } else { hidden.insert(row.id) }
        }
        apps.enabled = appsInSearch ? nil : false
        apps.aliases = aliases
        apps.hotkeys = hotkeys
        apps.hidden = hidden.sorted()
        config.applications = apps
        do {
            try config.save()
            error = apply()
        } catch {
            self.error = "Couldn't save config.json: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Launch at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseWorkspacesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: Config.expand(workspacesRoot), isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            workspacesRoot = url.tildePath
        }
    }

    /// Lets the user pick any app; returns its name for `open -a`.
    func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    func matchesFilter(_ row: AppRow) -> Bool {
        let q = appFilter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || [row.app.name, row.app.fileName, row.alias, row.app.bundleId ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Choices

    var terminalChoices: [AppChoice] {
        let known: [(String, String, String)] = [
            ("ghostty", "Ghostty", "com.mitchellh.ghostty"),
            ("terminal", "Terminal", "com.apple.Terminal"),
            ("iterm", "iTerm", "com.googlecode.iterm2"),
            ("warp", "Warp", "dev.warp.Warp-Stable"),
        ]
        var out = known.filter { Self.isInstalled($0.2) }.map { AppChoice(value: $0.0, name: $0.1) }
        if !out.contains(where: { $0.value.caseInsensitiveCompare(terminal) == .orderedSame }) {
            out.append(AppChoice(value: terminal, name: Config.terminalName(terminal)))
        }
        return out
    }

    var editorChoices: [AppChoice] {
        let known = [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf",
            "com.sublimetext.4", "com.panic.Nova", "com.apple.dt.Xcode",
        ]
        var names = known.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent
        }
        if !names.contains(editor) { names.append(editor) }
        return names.map { AppChoice(value: $0, name: $0) }
    }

    var defaultAgentChoices: [AppChoice] {
        var out = agents.filter { $0.installed && $0.enabled }.map { AppChoice(value: $0.id, name: $0.name) }
        if !out.contains(where: { $0.value == defaultAgent }) {
            let name = agents.first { $0.id == defaultAgent }?.name ?? defaultAgent
            out.append(AppChoice(value: defaultAgent, name: "\(name) (unavailable)"))
        }
        return out
    }

    private static func isInstalled(_ bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}

/// Shell-style argument lists <-> a single editable line.
enum Args {
    static func join(_ args: [String]) -> String {
        args.map { arg in
            arg.isEmpty || arg.contains(where: { " \t\"'\\".contains($0) }) ? Shell.quote(arg) : arg
        }.joined(separator: " ")
    }

    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch); escaped = false
            } else if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inToken = true
            } else if ch == "\\" {
                escaped = true; inToken = true
            } else if ch.isWhitespace {
                if inToken { out.append(current); current = ""; inToken = false }
            } else {
                current.append(ch); inToken = true
            }
        }
        if inToken { out.append(current) }
        return out
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Summonbar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }()

    func show() {
        if !window.isVisible {
            model.load()
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                GeneralSettings(model: model)
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsModel.Tab.general)
                AgentSettings(model: model)
                    .tabItem { Label("Agents", systemImage: "sparkles") }
                    .tag(SettingsModel.Tab.agents)
                ApplicationSettings(model: model)
                    .tabItem { Label("Applications", systemImage: "square.grid.2x2") }
                    .tag(SettingsModel.Tab.applications)
                ShortcutSettings(model: model)
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                    .tag(SettingsModel.Tab.shortcuts)
            }
            .padding(.top, 8)
            footer
        }
        .frame(width: 560, height: 580)
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("Changes are saved automatically.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open config.json") {
                model.saveNow()
                NSWorkspace.shared.open(Config.fileURL)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    private static let chooseTag = "\u{0}choose"

    var body: some View {
        Form {
            Section("Launcher") {
                LabeledContent("Hotkey") {
                    HotKeyRecorder(spec: $model.hotkey, onRecordingChange: model.pauseHotKey)
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }

            UpdateSettings(model: model)

            Section {
                LabeledContent("Workspaces folder") {
                    HStack {
                        TextField("", text: $model.workspacesRoot, prompt: Text("~/Workspaces"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { model.chooseWorkspacesRoot() }
                    }
                }
                Toggle("Run git init in new projects", isOn: $model.gitInitNewProjects)
            } header: {
                Text("Projects")
            } footer: {
                Text("Top-level folders are projects; folders that only hold projects (like a company folder) are expanded.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Translate to", selection: $model.translateTo) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                Picker("Text already in \(Language.name(model.translateTo))", selection: $model.translateAlternate) {
                    Text("Default (\(TranslationConfig(to: model.translateTo).fallback.map(Language.name) ?? "none"))").tag(String?.none)
                    Text("Leave as is").tag(String?.some(""))
                    Divider()
                    ForEach(Language.all.filter { $0.code != model.translateTo }) { Text($0.name).tag(String?.some($0.code)) }
                }
            } header: {
                Text("Translate")
            } footer: {
                Text("Type “tr ” and the text in the launcher. Text is sent to Google Translate.")
                    .foregroundStyle(.secondary)
            }

            Section("Apps") {
                Picker("Terminal", selection: appBinding(\.terminal)) {
                    ForEach(model.terminalChoices, id: \.self) { Text($0.name).tag($0.value) }
                    Divider()
                    Text("Other App…").tag(Self.chooseTag)
                }
                Picker("Editor", selection: appBinding(\.editor)) {
                    ForEach(model.editorChoices, id: \.self) { Text($0.name).tag($0.value) }
                    Divider()
                    Text("Other App…").tag(Self.chooseTag)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A picker binding where the "Other App…" entry opens an app chooser.
    private func appBinding(_ keyPath: ReferenceWritableKeyPath<SettingsModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { value in
                if value == Self.chooseTag {
                    if let app = model.chooseApp() { model[keyPath: keyPath] = app }
                } else {
                    model[keyPath: keyPath] = value
                }
            })
    }
}

private struct UpdateSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            LabeledContent("Summonbar \(updater.currentVersion)") {
                HStack {
                    if updater.isBusy { ProgressView().controlSize(.small) }
                    Button(updater.available.map { "Install \($0.version) & Relaunch" } ?? "Check Now") { model.updateSummonbar() }
                        .disabled(updater.isBusy)
                }
            }
            Toggle("Check for updates automatically", isOn: $model.checkForUpdates)
        } header: {
            Text("Updates")
        } footer: {
            Text(status).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch updater.state {
        case .checking: return "Checking GitHub for a new release…"
        case .installing(let release): return "Downloading and installing \(release.version)…"
        case .available(let release): return "\(release.name) is available. Updating replaces this copy and relaunches; your settings and runs are kept."
        case .failed(let message): return message
        case .idle, .upToDate:
            let checked = updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? ""
            return "Updates install in place from GitHub Releases, no reinstall needed. \(checked)"
        }
    }
}

private struct AgentSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: $model.defaultAgent) {
                    ForEach(model.defaultAgentChoices, id: \.self) { Text($0.name).tag($0.value) }
                }
            } footer: {
                Text("Used for “Ask …” in the root search and ⌘↵ on a project.")
                    .foregroundStyle(.secondary)
            }

            ForEach($model.agents) { $agent in
                Section {
                    if agent.installed {
                        Toggle("Show in launcher", isOn: $agent.enabled)
                        if agent.enabled {
                            ArgsField(title: "Terminal arguments", text: $agent.args,
                                      help: "Added when the agent opens in your terminal.")
                            ArgsField(title: "Inline run arguments", text: $agent.headlessArgs,
                                      help: "Added to runs inside the launcher, e.g. permission or sandbox flags.")
                        }
                    }
                } header: {
                    AgentHeader(agent: agent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ApplicationSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Show applications in search", isOn: $model.appsInSearch)
            } footer: {
                Text("Hotkeys work either way. Pressing an app's hotkey while it's frontmost hides it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.appRows) { $row in
                    if model.matchesFilter(row) {
                        AppSettingsRow(row: $row, pauseHotKey: model.pauseHotKey)
                    }
                }
            } header: {
                HStack {
                    Text("\(model.appRows.count) installed")
                    Spacer()
                    TextField("", text: $model.appFilter, prompt: Text("Filter"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}

/// Every keyboard shortcut in one place; the global ones reflect the current config.
private struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel

    private static let launcher = [
        ("Move selection", "↑ ↓"),
        ("Run the selected item", "↵"),
        ("Secondary action (shown in the footer)", "⌘↵"),
        ("Show actions for the selected item", "⌘K"),
        ("Reveal the selected item in Finder", "⇧⌘F"),
        ("Open a project's prompt, or fill in arguments", "⇥"),
        ("Go back, or close Summonbar", "esc"),
        ("Go back when the field is empty", "⌫"),
        ("Reload projects & config", "⌘R"),
        ("Open Settings", "⌘,"),
    ]
    private static let agentRun = [
        ("Send a follow-up, or Allow & Retry", "↵"),
        ("Stop the agent", "⌘."),
        ("Continue in the terminal", "⌘T"),
    ]
    private static let extensionOutput = [
        ("Send to agent, or run again", "↵"),
        ("Copy the prompt", "⌘↵"),
        ("Stop the extension", "⌘."),
    ]
    private static let translate = [
        ("Copy the translation", "↵"),
        ("Swap languages", "⌘↵"),
        ("Pick a language", "⌘K"),
    ]
    private static let prefixes = [
        ("Create a new project", "new …"),
        ("Translate text", "tr …"),
        ("Run a slash command or skill (in a project's prompt)", "/ …"),
    ]

    var body: some View {
        Form {
            Section {
                ShortcutRow(label: "Open Summonbar", keys: HotKey.describe(model.hotkey))
                ForEach(model.appRows.filter { !$0.hotkey.isEmpty }) { row in
                    ShortcutRow(label: "Open \(row.app.name)", keys: HotKey.describe(row.hotkey))
                }
            } header: {
                Text("Global")
            } footer: {
                Text("Change these under General and Applications.").foregroundStyle(.secondary)
            }
            section("Launcher", Self.launcher)
            section("Agent run", Self.agentRun)
            section("Extension output", Self.extensionOutput)
            section("Translate", Self.translate)
            section("Type in the search field", Self.prefixes)
        }
        .formStyle(.grouped)
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        Section(title) {
            ForEach(rows, id: \.0) { ShortcutRow(label: $0.0, keys: $0.1) }
        }
    }
}

private struct ShortcutRow: View {
    let label: String
    let keys: String

    var body: some View {
        LabeledContent(label) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct AppSettingsRow: View {
    @Binding var row: SettingsModel.AppRow
    var pauseHotKey: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppControl.icon(row.app.url.path)).resizable().frame(width: 20, height: 20)
            Text(row.app.name)
                .lineLimit(1)
                .foregroundStyle(row.visible ? .primary : .secondary)
                .help(row.app.url.tildePath)
            Spacer(minLength: 8)
            TextField("", text: $row.alias, prompt: Text("Alias"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            HotKeyRecorder(spec: $row.hotkey, onRecordingChange: pauseHotKey, placeholder: "Record Hotkey", minWidth: 100)
                .controlSize(.small)
            Button { row.hotkey = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(row.hotkey.isEmpty ? 0 : 1)
                .disabled(row.hotkey.isEmpty)
                .help("Remove hotkey")
            Toggle("", isOn: $row.visible)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show in search")
        }
    }
}

private struct AgentHeader: View {
    let agent: SettingsModel.AgentRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: agent.icon)
                .foregroundStyle(agent.installed ? .purple : .secondary)
                .frame(width: 18)
            Text(agent.name)
            Spacer()
            Text(agent.path.map { URL(fileURLWithPath: $0).tildePath } ?? "Not found on PATH")
                .font(.system(size: 11, design: agent.installed ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .textCase(nil)
    }
}

private struct ArgsField: View {
    let title: String
    @Binding var text: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(text: $text, prompt: Text("none")) {
                Text(title).font(.body)
            }
            .font(.system(size: 12, design: .monospaced))
            Text(help)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Click, then press a shortcut. Esc cancels.
private struct HotKeyRecorder: View {
    @Binding var spec: String
    var onRecordingChange: (Bool) -> Void
    var placeholder = ""
    var minWidth: CGFloat = 130
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press a shortcut…" : spec.isEmpty ? placeholder : HotKey.describe(spec))
                .font(.system(size: 13, weight: recording || spec.isEmpty ? .regular : .medium))
                .foregroundStyle(recording || spec.isEmpty ? .secondary : .primary)
                .frame(minWidth: minWidth)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // esc
                stop()
            } else if let new = HotKey.spec(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                stop()
                spec = new
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChange(false)
    }
}
