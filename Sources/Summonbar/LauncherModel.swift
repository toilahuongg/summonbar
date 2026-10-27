import AppKit
import ServiceManagement
import SwiftUI

struct ListItem: Identifiable {
    let id: String
    var section: String
    var title: String
    var subtitle: String? = nil
    var icon: String
    var tint: Color = .secondary
    var accessory: String? = nil
    var primaryLabel = "Open"
    var primary: () -> Void
    var secondaryLabel: String? = nil
    var secondary: (() -> Void)? = nil
    var actions: (() -> [ListItem])? = nil
}

enum Screen {
    case root
    case actions(title: String, items: [ListItem])
    case prompt(Project)
    case run(AgentRun)
    case runs
    /// Collects extension arguments one at a time; with all collected it asks to confirm.
    case argument(Extension, Project, [String])
    /// The prompt an extension built, before it goes to the agent (preview, or a failed script).
    case output(ExtensionRun)
    /// Takes the arguments for a project's Claude Code command or skill.
    case slash(SlashCommand, Project)
}

@MainActor
final class LauncherModel: ObservableObject {
    private struct Frame {
        var screen: Screen
        var query = ""
        var selection = 0
    }

    @Published var query = "" {
        didSet { if query != oldValue { selection = 0; refresh() } }
    }
    @Published var selection = 0
    @Published private(set) var items: [ListItem] = []
    @Published private(set) var focusTick = 0
    @Published private(set) var toast: String?
    @Published private(set) var runs: [AgentRun] = []
    @Published private var frames: [Frame] = [Frame(screen: .root)]

    private(set) var config = Config.load()
    private(set) var agents: [Agent] = []
    private(set) var projects: [Project] = []
    private(set) var extensions: [Extension] = []
    private var activeExtensionRuns: [ExtensionRun] = []
    /// Per-project `.claude` commands and skills, read again on reload and each time the launcher opens.
    private var slashCache: [URL: [SlashCommand]] = [:]
    private var usage = Store.loadUsage()
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    var hidePanel: () -> Void = {}
    var openSettings: () -> Void = {}
    var runsChanged: () -> Void = {}

    init() {
        reload()
        runs = Store.loadRuns().map { record in
            let run = AgentRun(record: record, agent: agents.first { $0.id == record.agentId })
            run.onChange = { [weak self] in self?.runDidChange() }
            return run
        }
        refresh()
    }

    // MARK: - State

    var screen: Screen { frames.last!.screen }
    var isRoot: Bool { frames.count == 1 }
    var selectedItem: ListItem? { items.indices.contains(selection) ? items[selection] : nil }
    var defaultAgent: Agent? { agents.first }
    /// Project commands and skills are Claude Code's, so they always go to it.
    var claudeAgent: Agent? { agents.first { $0.id == "claude" } }
    var runningCount: Int { runs.filter(\.isRunning).count }

    private var pendingArgument: ExtensionArgument? {
        guard case .argument(let ext, _, let values) = screen, values.count < ext.arguments.count else { return nil }
        return ext.arguments[values.count]
    }

    var placeholder: String {
        switch screen {
        case .root: return "Search projects, or ask an agent…"
        case .actions: return "Search actions…"
        case .prompt(let p): return "What should the agent do in \(p.name)?"
        case .run(let run): return run.isRunning ? "\(run.agentName) is working…" : (run.canFollowUp ? "Send a follow-up…" : "This agent can't continue the conversation inline")
        case .runs: return "Search agent runs…"
        case .argument(let ext, _, _):
            guard let arg = pendingArgument else { return "Press ↵ to run \(ext.title)" }
            return arg.kind == .dropdown ? "Choose \(arg.placeholder)…" : arg.placeholder + (arg.optional ? " (optional)" : "")
        case .output(let run):
            if run.isRunning { return "\(run.ext.title) is building the prompt…" }
            return run.prompt != nil ? "Press ↵ to send to \(agent(for: run.ext)?.name ?? "the agent")" : "Press ↵ to run again"
        case .slash(let cmd, _): return cmd.argumentHint.map { "Arguments: \($0)" } ?? "Arguments for \(cmd.invocation) (optional)"
        }
    }

    var breadcrumb: String? {
        switch screen {
        case .root: return nil
        case .actions(let title, _): return title
        case .prompt(let p): return p.name
        case .run(let run): return "\(run.agentName) · \(run.projectName)"
        case .runs: return "Agent Runs"
        case .argument(let ext, let project, _): return "\(ext.title) · \(project.name)"
        case .output(let run): return "\(run.ext.title) · \(run.project.name)"
        case .slash(let cmd, let project): return "\(cmd.invocation) · \(project.name)"
        }
    }

    var hints: [(label: String, keys: String)] {
        if case .run(let run) = screen {
            var h: [(String, String)] = []
            if run.isRunning { h.append(("Stop", "⌘.")) } else if run.canFollowUp { h.append(("Send", "↵")) }
            if run.agent != nil { h.append(("Continue in \(config.terminalName)", "⌘T")) }
            h.append(("Back", "esc"))
            return h
        }
        if case .output(let run) = screen {
            let primary = run.isRunning ? ("Stop", "⌘.") : (run.prompt != nil ? ("Send to Agent", "↵") : ("Run Again", "↵"))
            return [primary, ("Copy Prompt", "⌘↵"), ("Back", "esc")]
        }
        guard let item = selectedItem else { return [("Back", "esc")] }
        var h = [(item.primaryLabel, "↵")]
        if let label = item.secondaryLabel { h.append((label, "⌘↵")) }
        if item.actions != nil { h.append(("Actions", "⌘K")) }
        return h
    }

    // MARK: - Lifecycle

    func reload() {
        config = Config.load()
        agents = AgentCatalog.detect(config: config)
        projects = ProjectScanner.scan(root: config.workspacesRoot)
        extensions = ExtensionCatalog.scan(config: config)
        slashCache = [:]
    }

    func didShow() {
        if isRoot {
            projects = ProjectScanner.scan(root: config.workspacesRoot)
            slashCache = [:]
            refresh()
        }
        focusTick += 1
    }

    func show(run: AgentRun) {
        frames = [Frame(screen: .root)]
        push(.run(run))
    }

    func showRuns() {
        frames = [Frame(screen: .root)]
        push(.runs)
    }

    // MARK: - Navigation

    private func push(_ screen: Screen, query newQuery: String = "") {
        frames[frames.count - 1].query = query
        frames[frames.count - 1].selection = selection
        frames.append(Frame(screen: screen))
        setQuery(newQuery)
        focusTick += 1
    }

    func back() {
        guard frames.count > 1 else { hidePanel(); return }
        frames.removeLast()
        let frame = frames.last!
        setQuery(frame.query)
        selection = min(frame.selection, max(items.count - 1, 0))
        focusTick += 1
    }

    /// Swaps the top screen without growing the stack (next extension argument).
    private func replaceTop(_ screen: Screen) {
        frames[frames.count - 1] = Frame(screen: screen)
        setQuery("")
        focusTick += 1
    }

    private func resetToRoot() {
        frames = [Frame(screen: .root)]
        setQuery("")
    }

    private func setQuery(_ value: String) {
        if query == value { refresh() } else { query = value }
        selection = 0
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    func performPrimary() {
        if case .run(let run) = screen { sendFollowUp(run); return }
        if case .output(let run) = screen {
            if run.isRunning { return }
            if let prompt = run.prompt { sendToAgent(run.ext, run.project, prompt) } else { launch(run) }
            return
        }
        selectedItem?.primary()
    }

    func performSecondary() {
        if case .run(let run) = screen { continueInTerminal(run); return }
        if case .output(let run) = screen { copy(run.output, label: "prompt"); return }
        guard let item = selectedItem else { return }
        (item.secondary ?? item.primary)()
    }

    func showActions() {
        guard let item = selectedItem, let actions = item.actions?() else { return }
        push(.actions(title: item.title, items: actions))
    }

    func enterSelected() {
        if let item = selectedItem, item.id.hasPrefix("x:") { item.primary(); return }
        if let item = selectedItem, item.id.hasPrefix("s:"), let addArguments = item.actions?().first {
            addArguments.primary()
            return
        }
        guard case .root = screen, let item = selectedItem, item.id.hasPrefix("p:"),
              let project = projects.first(where: { "p:" + $0.id == item.id }) else { return }
        push(.prompt(project))
    }

    /// Returns true when the key was handled and should not reach the text field.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let inRun: Bool = {
            switch screen {
            case .run, .output: return true
            default: return false
            }
        }()

        switch event.keyCode {
        case 53: back(); return true                                   // esc
        case 126 where !inRun: move(-1); return true                   // ↑
        case 125 where !inRun: move(1); return true                    // ↓
        case 36, 76: cmd ? performSecondary() : performPrimary(); return true  // ↵
        case 48 where !inRun: enterSelected(); return true             // tab
        case 51 where query.isEmpty && !isRoot: back(); return true    // ⌫ on empty field
        default: break
        }
        guard cmd else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": showActions(); return true
        case "t": if case .run(let run) = screen { continueInTerminal(run) }; return true
        case ".":
            if case .run(let run) = screen { run.stop() }
            if case .output(let run) = screen { run.stop() }
            return true
        case ",": finish(); openSettings(); return true
        case "r": reloadAndReport(); return true
        default: return false
        }
    }

    // MARK: - Items

    func refresh() {
        switch screen {
        case .root: items = rootItems()
        case .actions(_, let actions): items = filter(actions)
        case .prompt(let p): items = promptItems(p)
        case .run: items = []
        case .runs: items = filter(runs.map(runItem))
        case .argument(let ext, let project, let values): items = argumentItems(ext, project, values)
        case .output: items = []
        case .slash(let cmd, let project): items = slashArgumentItems(cmd, project)
        }
        if selection >= items.count { selection = max(items.count - 1, 0) }
    }

    private func filter(_ list: [ListItem]) -> [ListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.compactMap { item in Fuzzy.score(q, item.title).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    private var contextProject: Project? {
        let recent = usage.max { $0.value < $1.value }?.key
        return projects.first { $0.id == recent } ?? projects.first
    }

    private func sortedProjects() -> [Project] {
        projects.sorted { a, b in
            let ua = usage[a.id] ?? .distantPast, ub = usage[b.id] ?? .distantPast
            return ua != ub ? ua > ub : a.modified > b.modified
        }
    }

    private func rootItems() -> [ListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [ListItem] = []

        if query.lowercased().hasPrefix("new ") {
            let spec = q.dropFirst(3).trimmingCharacters(in: .whitespaces)
            out.append(createItem(spec))
            out += commandItems().filter { Fuzzy.score(q, $0.title) != nil }
            return out
        }

        if q.isEmpty {
            out += runs.prefix(3).map(runItem).map { var i = $0; i.section = "Recent Runs"; return i }
            out += sortedProjects().map(projectItem)
            out += commandItems()
            return out
        }

        let matches = projects.compactMap { p in Fuzzy.score(q, p.name).map { (p, $0) } }
            .sorted { $0.1 > $1.1 }.map { projectItem($0.0) }
        let asks = askItems(q)
        let found = matches + filter(contextProject.map { project in
            extensions.map { extensionItem($0, project: project, showProject: true) }
                + slashItems(project, showProject: true)
        } ?? [])
        out += found.isEmpty ? asks : found + asks
        if projects.allSatisfy({ $0.name.lowercased() != q.lowercased() }), Self.slug(q) != nil, !q.contains(" ") {
            out.append(createItem(q))
        }
        out += filter(commandItems())
        return out
    }

    private func askItems(_ prompt: String) -> [ListItem] {
        guard let project = contextProject else { return [] }
        return agents.prefix(3).map { agent in
            ListItem(id: "ask:\(agent.id)", section: "Ask Agent", title: "Ask \(agent.name): \(prompt)",
                     subtitle: "in \(project.name) · Tab on a project to pick another", icon: agent.icon, tint: .purple,
                     primaryLabel: "Run", primary: { [unowned self] in startRun(agent, project, prompt) },
                     secondaryLabel: "Open in \(config.terminalName)",
                     secondary: { [unowned self] in launch(agent, project, prompt: prompt) })
        }
    }

    private func projectItem(_ p: Project) -> ListItem {
        let agent = defaultAgent
        return ListItem(
            id: "p:" + p.id, section: "Projects", title: p.name, subtitle: p.kind,
            icon: "folder.fill", tint: .blue, accessory: relativeDate(p.modified),
            primaryLabel: "Ask Agent", primary: { [unowned self] in push(.prompt(p)) },
            secondaryLabel: agent.map { "Open \($0.name) in \(config.terminalName)" },
            secondary: agent.map { a in { [unowned self] in launch(a, p, prompt: nil) } },
            actions: { [unowned self] in projectActions(p) })
    }

    private func projectActions(_ p: Project) -> [ListItem] {
        var out: [ListItem] = []
        for agent in agents {
            out.append(ListItem(id: "a:term:\(agent.id)", section: "Agents", title: "Open \(agent.name) in \(config.terminalName)",
                                icon: "terminal", tint: .green, primaryLabel: "Open",
                                primary: { [unowned self] in launch(agent, p, prompt: nil) }))
        }
        out += projectExtensionItems(p)
        out += slashItems(p)
        out += utilityItems(p)
        return out
    }

    private func utilityItems(_ p: Project) -> [ListItem] {
        [
            ListItem(id: "u:editor", section: "Project", title: "Open in \(config.editor)", icon: "chevron.left.forwardslash.chevron.right",
                     tint: .blue, primary: { [unowned self] in markUsed(p); TerminalLauncher.openInEditor(p.url, editor: config.editor); finish() }),
            ListItem(id: "u:shell", section: "Project", title: "Open Shell in \(config.terminalName)", icon: "apple.terminal",
                     primary: { [unowned self] in markUsed(p); TerminalLauncher.open(command: nil, in: p.url, terminal: config.terminal); finish() }),
            ListItem(id: "u:finder", section: "Project", title: "Reveal in Finder", icon: "finder",
                     primary: { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([p.url]); finish() }),
            ListItem(id: "u:copy", section: "Project", title: "Copy Path", subtitle: p.url.tildePath, icon: "doc.on.doc",
                     primary: { [unowned self] in copy(p.url.path, label: p.url.tildePath) }),
        ]
    }

    private func promptItems(_ p: Project) -> [ListItem] {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [ListItem] = []
        for agent in agents {
            out.append(ListItem(
                id: "run:\(agent.id)", section: "Run Here", title: "Ask \(agent.name)",
                subtitle: prompt.isEmpty ? "Type a task above, then press ↵" : "Stream the answer inside Summonbar",
                icon: agent.icon, tint: .purple, primaryLabel: "Run",
                primary: { [unowned self] in
                    guard !prompt.isEmpty else { flash("Type what you want \(agent.name) to do first"); return }
                    startRun(agent, p, prompt)
                },
                secondaryLabel: "Open in \(config.terminalName)",
                secondary: { [unowned self] in launch(agent, p, prompt: prompt.isEmpty ? nil : prompt) }))
        }
        for agent in agents {
            out.append(ListItem(
                id: "term:\(agent.id)", section: "Interactive in \(config.terminalName)",
                title: prompt.isEmpty ? "Start \(agent.name)" : "Start \(agent.name) with this prompt",
                icon: "terminal", tint: .green, primaryLabel: "Open",
                primary: { [unowned self] in launch(agent, p, prompt: prompt.isEmpty ? nil : prompt) }))
        }
        out += runs.filter { $0.projectURL == p.url }.prefix(5).map { var i = runItem($0); i.section = "Previous Runs"; return i }
        out += projectExtensionItems(p)
        out += slashItems(p)
        out += utilityItems(p)
        // Typing `/name args` puts the matching commands and skills first.
        if prompt.hasPrefix("/") {
            let parts = prompt.dropFirst().split(separator: " ", maxSplits: 1)
            let token = parts.first.map(String.init) ?? ""
            let args = parts.count > 1 ? String(parts[1]) : ""
            let matches = slashCommands(p).filter { token.isEmpty || Fuzzy.score(token, $0.name) != nil }
            out.insert(contentsOf: matches.compactMap { slashItem($0, p, args: args) }, at: 0)
        }
        if agents.isEmpty {
            out.insert(ListItem(id: "noagents", section: "Run Here", title: "No coding agents found on PATH",
                                subtitle: "Install claude, codex, gemini, opencode, cursor-agent or aider, then ⌘R",
                                icon: "exclamationmark.triangle", tint: .orange, primary: {}), at: 0)
        }
        return out
    }

    private func runItem(_ run: AgentRun) -> ListItem {
        let icon: String, tint: Color
        switch run.status {
        case .running: (icon, tint) = ("circle.dotted", .orange)
        case .done: (icon, tint) = ("checkmark.circle.fill", .green)
        case .failed: (icon, tint) = ("xmark.octagon.fill", .red)
        case .stopped: (icon, tint) = ("stop.circle", .secondary)
        }
        return ListItem(
            id: "r:\(run.id)", section: "Agent Runs", title: run.title.isEmpty ? "(untitled)" : run.title,
            subtitle: "\(run.agentName) · \(run.projectName)", icon: icon, tint: tint,
            accessory: run.isRunning ? "running" : relativeDate(run.createdAt),
            primaryLabel: "Open Run", primary: { [unowned self] in push(.run(run)) },
            secondaryLabel: run.agent != nil ? "Continue in \(config.terminalName)" : nil,
            secondary: run.agent != nil ? { [unowned self] in continueInTerminal(run) } : nil)
    }

    private func createItem(_ spec: String) -> ListItem {
        // "new name: what to build" creates the folder and pre-fills the prompt.
        let parts = spec.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.first.flatMap { Self.slug($0) }
        let prompt = parts.count > 1 ? parts[1] : ""
        let root = config.workspacesRoot.tildePath
        guard let name else {
            return ListItem(id: "create", section: "Create", title: "New project: type a name",
                            subtitle: "new <name>  or  new <name>: <what to build>   →  \(root)/<name>",
                            icon: "folder.badge.plus", tint: .orange, primaryLabel: "Create",
                            primary: { [unowned self] in flash("Type a project name after “new ”") })
        }
        return ListItem(id: "create", section: "Create", title: "Create Project “\(name)”",
                        subtitle: "\(root)/\(name)" + (prompt.isEmpty ? "" : "  ·  then ask: \(prompt)"),
                        icon: "folder.badge.plus", tint: .orange, primaryLabel: "Create",
                        primary: { [unowned self] in createProject(name, prompt: prompt) })
    }

    private func commandItems() -> [ListItem] {
        let loginEnabled = SMAppService.mainApp.status == .enabled
        return [
            ListItem(id: "c:new", section: "Commands", title: "New Project", subtitle: "Create a folder in \(config.workspacesRoot.tildePath)",
                     icon: "folder.badge.plus", tint: .orange, primary: { [unowned self] in query = "new " }),
            ListItem(id: "c:runs", section: "Commands", title: "Agent Runs", subtitle: "\(runs.count) runs",
                     icon: "list.bullet.rectangle", tint: .purple, primary: { [unowned self] in push(.runs) }),
            ListItem(id: "c:workspaces", section: "Commands", title: "Open Workspaces Folder", icon: "folder",
                     primary: { [unowned self] in NSWorkspace.shared.open(config.workspacesRoot); finish() }),
            ListItem(id: "c:extensions", section: "Commands", title: "Open Extensions Folder",
                     subtitle: "\(extensions.count) extensions in \(ExtensionCatalog.directory.tildePath)", icon: "puzzlepiece.extension",
                     primary: { [unowned self] in NSWorkspace.shared.open(ExtensionCatalog.directory); finish() }),
            ListItem(id: "c:reload", section: "Commands", title: "Reload Projects & Config", icon: "arrow.clockwise", accessory: "⌘R",
                     primary: { [unowned self] in reloadAndReport() }),
            ListItem(id: "c:settings", section: "Commands", title: "Settings", subtitle: "Hotkey, folders, terminal, agents",
                     icon: "gearshape", accessory: "⌘,", primary: { [unowned self] in finish(); openSettings() }),
            ListItem(id: "c:config", section: "Commands", title: "Edit Config File", subtitle: Config.fileURL.tildePath,
                     icon: "doc.text", primary: { [unowned self] in openConfig() }),
            ListItem(id: "c:login", section: "Commands", title: loginEnabled ? "Disable Launch at Login" : "Enable Launch at Login",
                     icon: "power", primary: { [unowned self] in toggleLaunchAtLogin() }),
            ListItem(id: "c:quit", section: "Commands", title: "Quit Summonbar", icon: "xmark.circle",
                     primary: { NSApp.terminate(nil) }),
        ]
    }

    // MARK: - Actions

    func ask(agentId: String, path: String, prompt: String) {
        guard let agent = agents.first(where: { $0.id == agentId }) else {
            flash("Agent “\(agentId)” not found on PATH")
            return
        }
        let url = URL(fileURLWithPath: Config.expand(path), isDirectory: true).standardizedFileURL
        let project = projects.first { $0.url.standardizedFileURL == url } ?? ProjectScanner.make(url, root: config.workspacesRoot)
        frames = [Frame(screen: .root)]
        startRun(agent, project, prompt)
    }

    private func startRun(_ agent: Agent, _ project: Project, _ prompt: String) {
        markUsed(project)
        let run = AgentRun(agent: agent, project: project)
        run.onChange = { [weak self] in self?.runDidChange() }
        runs.insert(run, at: 0)
        push(.run(run))
        run.send(prompt)
    }

    private func sendFollowUp(_ run: AgentRun) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard run.canFollowUp else {
            flash(run.isRunning ? "Wait for the agent to finish, or ⌘. to stop" : "Continue this one in the terminal with ⌘T")
            return
        }
        query = ""
        run.send(text)
        if let index = runs.firstIndex(where: { $0 === run }), index != 0 {
            runs.remove(at: index)
            runs.insert(run, at: 0)
        }
    }

    private func continueInTerminal(_ run: AgentRun) {
        guard let agent = run.agent else { return }
        run.stop()
        let resume = agent.canResume ? run.sessionId : nil
        let command = agent.interactiveCommand(prompt: nil, resume: resume)
        TerminalLauncher.open(command: command, in: run.projectURL, terminal: config.terminal)
        finish()
    }

    private func launch(_ agent: Agent, _ project: Project, prompt: String?) {
        markUsed(project)
        TerminalLauncher.open(command: agent.interactiveCommand(prompt: prompt, resume: nil), in: project.url, terminal: config.terminal)
        finish()
    }

    private func createProject(_ name: String, prompt: String) {
        let url = config.workspacesRoot.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        if !existed {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                flash("Couldn't create \(url.tildePath): \(error.localizedDescription)")
                return
            }
            if config.gitInitNewProjects { Shell.run("/usr/bin/git", ["init", "-q"], in: url) }
        }
        let project = ProjectScanner.make(url, root: config.workspacesRoot)
        projects = ProjectScanner.scan(root: config.workspacesRoot)
        if !projects.contains(project) { projects.insert(project, at: 0) }
        markUsed(project)
        frames = [Frame(screen: .root)]
        push(.prompt(project), query: prompt)
        flash(existed ? "\(url.tildePath) already exists — opened it" : "Created \(url.tildePath)")
    }

    // MARK: - Extensions

    private func agent(for ext: Extension) -> Agent? {
        agents.first { $0.id == ext.agentId } ?? defaultAgent
    }

    private func extensionItem(_ ext: Extension, project: Project, showProject: Bool = false) -> ListItem {
        ListItem(
            id: "x:\(ext.id)", section: "Extensions", title: ext.title,
            subtitle: showProject ? "in \(project.name) · ⌘K on a project to pick another" : ext.description,
            icon: ext.icon, tint: .teal,
            primaryLabel: "Ask \(agent(for: ext)?.name ?? "Agent")",
            primary: { [unowned self] in runExtension(ext, project) },
            secondaryLabel: "Preview Prompt",
            secondary: { [unowned self] in runExtension(ext, project, preview: true) },
            actions: { [unowned self] in
                [
                    ListItem(id: "xa:preview", section: ext.title, title: "Preview Prompt", subtitle: "Run the script without sending it",
                             icon: "eye", tint: .teal,
                             primary: { [unowned self] in runExtension(ext, project, preview: true) }),
                    ListItem(id: "xa:edit", section: ext.title, title: "Edit Script in \(config.editor)", subtitle: ext.url.tildePath,
                             icon: "chevron.left.forwardslash.chevron.right", tint: .blue,
                             primary: { [unowned self] in TerminalLauncher.openInEditor(ext.url, editor: config.editor); finish() }),
                    ListItem(id: "xa:finder", section: ext.title, title: "Reveal in Finder", icon: "finder",
                             primary: { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([ext.url]); finish() }),
                ]
            })
    }

    private func projectExtensionItems(_ p: Project) -> [ListItem] {
        extensions.map { extensionItem($0, project: p) }
    }

    private func argumentItems(_ ext: Extension, _ project: Project, _ values: [String]) -> [ListItem] {
        guard values.count < ext.arguments.count else {
            return [ListItem(id: "x:confirm", section: "Confirm", title: "Run \(ext.title)", subtitle: ext.description,
                             icon: ext.icon, tint: .orange, primaryLabel: "Run",
                             primary: { [unowned self] in runExtension(ext, project, values: values, confirmed: true) })]
        }
        let arg = ext.arguments[values.count]
        let step = ext.arguments.count > 1 ? " · \(values.count + 1) of \(ext.arguments.count)" : ""
        let isLast = values.count + 1 == ext.arguments.count
        let submit: (String) -> Void = { [unowned self] value in runExtension(ext, project, values: values + [value]) }
        if arg.kind == .dropdown {
            return filter(arg.options.enumerated().map { index, option in
                ListItem(id: "x:opt:\(index)", section: arg.placeholder + step, title: option.title,
                         subtitle: option.value == option.title ? nil : option.value, icon: "list.bullet", tint: .teal,
                         primaryLabel: isLast ? "Run" : "Next", primary: { submit(option.value) })
            })
        }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if value.isEmpty && !arg.optional { title = "Type \(arg.placeholder.lowercased()) above" }
        else if isLast { title = "Run \(ext.title)" }
        else { title = value.isEmpty ? "Skip \(arg.placeholder)" : "Next" }
        return [ListItem(id: "x:submit", section: arg.placeholder + step, title: title, subtitle: ext.description,
                         icon: ext.icon, tint: .teal, primaryLabel: isLast ? "Run" : "Next",
                         primary: { [unowned self] in
                             guard !value.isEmpty || arg.optional else { flash("\(arg.placeholder) is required"); return }
                             submit(value)
                         })]
    }

    /// Collects missing arguments and confirmation, then runs the extension.
    /// With `preview`, the prompt is shown instead of being sent.
    private func runExtension(_ ext: Extension, _ project: Project, values: [String] = [],
                              confirmed: Bool = false, preview: Bool = false) {
        if values.count < ext.arguments.count || (ext.needsConfirmation && !confirmed && !preview) {
            let next = Screen.argument(ext, project, values)
            if case .argument = screen { replaceTop(next) } else { push(next) }
            return
        }
        if case .argument = screen { back() }
        markUsed(project)
        let env = [
            "SUMMONBAR_WORKSPACES": config.workspacesRoot.path,
            "SUMMONBAR_PROJECT_DIR": project.url.path,
            "SUMMONBAR_PROJECT_NAME": project.name,
        ]
        let run = ExtensionRun(ext: ext, project: project, arguments: values,
                               environment: Shell.env.merging(env) { _, ours in ours })
        run.onFinish = { [unowned self] run in
            activeExtensionRuns.removeAll { $0 === run }
            extensionFinished(run, preview: preview)
        }
        if preview { push(.output(run)) } else { flash("Running \(ext.title)…") }
        launch(run)
    }

    private func launch(_ run: ExtensionRun) {
        activeExtensionRuns.append(run)
        run.start()
    }

    private func extensionFinished(_ run: ExtensionRun, preview: Bool) {
        // A preview stays on screen; ↵ there sends the prompt.
        if case .output(let shown) = screen, shown === run { return }
        guard !preview else { return }
        guard let prompt = run.prompt else {
            if run.status == .failed { push(.output(run)) }
            else if run.status == .done { flash("\(run.ext.title) printed nothing to send") }
            return
        }
        sendToAgent(run.ext, run.project, prompt)
    }

    private func sendToAgent(_ ext: Extension, _ project: Project, _ prompt: String) {
        guard let agent = agent(for: ext) else { flash("No coding agent to send \(ext.title) to"); return }
        if case .output = screen { back() }
        startRun(agent, project, prompt)
    }

    // MARK: - Claude Code commands and skills

    private func slashCommands(_ p: Project) -> [SlashCommand] {
        if let cached = slashCache[p.url] { return cached }
        let found = SlashCommandScanner.scan(project: p.url)
        slashCache[p.url] = found
        return found
    }

    private func slashItems(_ p: Project, showProject: Bool = false) -> [ListItem] {
        slashCommands(p).compactMap { slashItem($0, p, showProject: showProject) }
    }

    private func slashItem(_ cmd: SlashCommand, _ p: Project, args: String = "", showProject: Bool = false) -> ListItem? {
        guard let claude = claudeAgent else { return nil }
        let prompt = args.isEmpty ? cmd.invocation : "\(cmd.invocation) \(args)"
        let wantsArguments = args.isEmpty && cmd.argumentHint != nil
        return ListItem(
            id: "s:\(cmd.id)", section: cmd.kind == .skill ? "Claude Skills" : "Claude Commands", title: prompt,
            subtitle: showProject ? "in \(p.name) · ⌘K on a project to pick another" : cmd.description,
            icon: cmd.kind == .skill ? "wand.and.stars" : "slash.circle", tint: .purple, accessory: args.isEmpty ? cmd.argumentHint : nil,
            primaryLabel: wantsArguments ? "Add Arguments" : "Ask \(claude.name)",
            primary: { [unowned self] in wantsArguments ? push(.slash(cmd, p)) : startRun(claude, p, prompt) },
            secondaryLabel: "Open in \(config.terminalName)",
            secondary: { [unowned self] in launch(claude, p, prompt: prompt) },
            actions: { [unowned self] in
                [
                    ListItem(id: "sa:args", section: cmd.invocation, title: "Run with Arguments…", icon: "text.cursor", tint: .purple,
                             primary: { [unowned self] in push(.slash(cmd, p)) }),
                    ListItem(id: "sa:term", section: cmd.invocation, title: "Open in \(config.terminalName)", icon: "terminal", tint: .green,
                             primary: { [unowned self] in launch(claude, p, prompt: prompt) }),
                    ListItem(id: "sa:edit", section: cmd.invocation, title: "Edit in \(config.editor)", subtitle: cmd.url.tildePath,
                             icon: "chevron.left.forwardslash.chevron.right", tint: .blue,
                             primary: { [unowned self] in TerminalLauncher.openInEditor(cmd.url, editor: config.editor); finish() }),
                    ListItem(id: "sa:finder", section: cmd.invocation, title: "Reveal in Finder", icon: "finder",
                             primary: { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([cmd.url]); finish() }),
                ]
            })
    }

    private func slashArgumentItems(_ cmd: SlashCommand, _ p: Project) -> [ListItem] {
        let args = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var item = slashItem(cmd, p, args: args) else {
            return [ListItem(id: "s:noclaude", section: cmd.invocation, title: "Claude Code isn't on PATH",
                             icon: "exclamationmark.triangle", tint: .orange, primary: {})]
        }
        // Here ↵ always runs, even with no arguments typed.
        let prompt = item.title
        item.section = cmd.argumentHint ?? "Arguments"
        item.subtitle = cmd.description
        item.primaryLabel = "Ask \(claudeAgent?.name ?? "Claude Code")"
        item.primary = { [unowned self] in if let claude = claudeAgent { startRun(claude, p, prompt) } }
        item.actions = nil
        return [item]
    }

    private func reloadAndReport() {
        reload()
        refresh()
        flash("Reloaded \(projects.count) projects, \(agents.count) agents, \(extensions.count) extensions")
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied \(label)")
    }

    private func openConfig() {
        _ = Config.load()  // writes the template if missing
        NSWorkspace.shared.open(Config.fileURL)
        finish()
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                flash("Launch at login disabled")
            } else {
                try SMAppService.mainApp.register()
                flash("Launch at login enabled")
            }
        } catch {
            flash("Launch at login failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Hide the launcher after handing off to another app.
    private func finish() {
        hidePanel()
        resetToRoot()
    }

    private func markUsed(_ project: Project) {
        usage[project.id] = Date()
        Store.saveUsage(usage)
    }

    func flash(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func runDidChange() {
        objectWillChange.send()
        runsChanged()
        if case .runs = screen { refresh() }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Store.saveRuns(runs.map(\.record))
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        Store.saveRuns(runs.map(\.record))
    }

    // MARK: - Helpers

    /// Folder names may include one level of grouping, e.g. `misoapps/new-app`.
    static func slug(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        guard !cleaned.isEmpty, cleaned.unicodeScalars.allSatisfy(allowed.contains),
              !cleaned.hasPrefix("/"), !cleaned.hasPrefix("."), !cleaned.contains(".."),
              !cleaned.hasSuffix("/") else { return nil }
        return cleaned
    }

    private func relativeDate(_ date: Date) -> String? {
        guard date > .distantPast else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
