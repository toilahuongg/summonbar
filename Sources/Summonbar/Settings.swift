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

    @Published var workspacesRoot = "" { didSet { scheduleSave() } }
    @Published var hotkey = "" { didSet { scheduleSave() } }
    @Published var terminal = "" { didSet { scheduleSave() } }
    @Published var editor = "" { didSet { scheduleSave() } }
    @Published var defaultAgent = "" { didSet { scheduleSave() } }
    @Published var gitInitNewProjects = true { didSet { scheduleSave() } }
    @Published var agents: [AgentRow] = [] { didSet { scheduleSave() } }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var error: String?

    /// Reloads the app from config.json; returns an error to show, if any.
    var apply: () -> String? = { nil }
    var pauseHotKey: (Bool) -> Void = { _ in }

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
        agents = AgentCatalog.specs.map { spec in
            let override = config.agents[spec.id]
            return AgentRow(id: spec.id, name: spec.name, icon: spec.icon, path: Shell.which(spec.binary),
                            enabled: override?.disabled != true,
                            args: Args.join(override?.args ?? []),
                            headlessArgs: Args.join(override?.headlessArgs ?? []),
                            configured: override != nil)
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
            TabView {
                GeneralSettings(model: model)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AgentSettings(model: model)
                    .tabItem { Label("Agents", systemImage: "sparkles") }
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
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press a shortcut…" : HotKey.describe(spec))
                .font(.system(size: 13, weight: recording ? .regular : .medium))
                .foregroundStyle(recording ? .secondary : .primary)
                .frame(minWidth: 130)
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
