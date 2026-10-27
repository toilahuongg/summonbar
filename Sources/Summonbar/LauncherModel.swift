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
    /// What ⇧⌘F reveals in Finder.
    var file: URL? = nil
}

enum Screen {
    case root
    case actions(title: String, items: [ListItem])
    case prompt(Project)
    case run(AgentRun)
    case runs
    /// Claude Code and Codex sessions saved on disk, optionally only one project's.
    case sessions(Project?)
    /// Collects extension arguments one at a time; with all collected it asks to confirm.
    case argument(Extension, Project, [String])
    /// The prompt an extension built, before it goes to the agent (preview, or a failed script).
    case output(ExtensionRun)
    /// Takes the arguments for a project's Claude Code command or skill.
    case slash(SlashCommand, Project)
    /// Installed apps, or only the running ones.
    case apps(running: Bool)
    /// Translates what's typed as you type.
    case translate(Translation)
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
    private var personalSlashCache: [SlashCommand]?
    private(set) var apps: [InstalledApp] = []
    private var appUsage = Store.loadUsage(apps: true)
    private var appScan: Task<Void, Never>?
    /// Backs the "tr <text>" item in the root search.
    private var rootTranslation: Translation?
    private var usage = Store.loadUsage()
    private var sessions: [AgentSession] = []
    private var sessionScan: Task<Void, Never>?
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    var hidePanel: () -> Void = {}
    var openSettings: () -> Void = {}
    var openApplicationSettings: (InstalledApp) -> Void = { _ in }
    var openShortcuts: () -> Void = {}
    var updateSummonbar: () -> Void = {}
    var runsChanged: () -> Void = {}

    init() {
        reload()
        runs = Store.loadRuns().map { record in
            let run = AgentRun(record: record, agent: agents.first { $0.id == record.agentId })
            run.onChange = { [weak self] in self?.runDidChange() }
            return run
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningAppsDidChange() }
            }
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
    /// Claude Code runs `.claude` commands and skills; `.agents` skills go to the default agent.
    private func agent(for cmd: SlashCommand) -> Agent? {
        cmd.isAgentSkill ? defaultAgent : claudeAgent
    }
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
        case .sessions: return "Search sessions…"
        case .argument(let ext, _, _):
            guard let arg = pendingArgument else { return "Press ↵ to run \(ext.title)" }
            return arg.kind == .dropdown ? "Choose \(arg.placeholder)…" : arg.placeholder + (arg.optional ? " (optional)" : "")
        case .output(let run):
            if run.isRunning { return "\(run.ext.title) is building the prompt…" }
            return run.prompt != nil ? "Press ↵ to send to \(agent(for: run.ext)?.name ?? "the agent")" : "Press ↵ to run again"
        case .slash(let cmd, _): return cmd.argumentHint.map { "Arguments: \($0)" } ?? "Arguments for \(cmd.invocation) (optional)"
        case .apps(let running): return running ? "Search running applications…" : "Search applications…"
        case .translate: return "Type or paste text to translate…"
        }
    }

    var breadcrumb: String? {
        switch screen {
        case .root: return nil
        case .actions(let title, _): return title
        case .prompt(let p): return p.name
        case .run(let run): return "\(run.agentName) · \(run.projectName)"
        case .runs: return "Agent Runs"
        case .sessions(let p): return p.map { "Sessions · \($0.name)" } ?? "Agent Sessions"
        case .argument(let ext, let project, _): return "\(ext.title) · \(project.name)"
        case .output(let run): return "\(run.ext.title) · \(run.project.name)"
        case .slash(let cmd, let project): return "\(cmd.invocation) · \(project.name)"
        case .apps(let running): return running ? "Running Applications" : "Applications"
        case .translate: return "Translate"
        }
    }

    var hints: [(label: String, keys: String)] {
        if case .run(let run) = screen {
            var h: [(String, String)] = []
            if run.isRunning {
                h.append(("Stop", "⌘."))
            } else if run.canFollowUp {
                h.append((query.isEmpty && !run.deniedRules.isEmpty ? "Allow & Retry" : "Send", "↵"))
            }
            if run.agent != nil { h.append(("Continue in \(config.terminalName)", "⌘T")) }
            h.append(("Back", "esc"))
            return h
        }
        if case .output(let run) = screen {
            let primary = run.isRunning ? ("Stop", "⌘.") : (run.prompt != nil ? ("Send to Agent", "↵") : ("Run Again", "↵"))
            return [primary, ("Copy Prompt", "⌘↵"), ("Back", "esc")]
        }
        if case .translate(let t) = screen {
            let primary = if case .failed = t.status { ("Try Again", "↵") } else { ("Copy Translation", "↵") }
            return [primary, ("Swap Languages", "⌘↵"), ("Language", "⌘K"), ("Back", "esc")]
        }
        guard let item = selectedItem else { return [("Back", "esc")] }
        var h = [(item.primaryLabel, "↵")]
        if let label = item.secondaryLabel { h.append((label, "⌘↵")) }
        if item.file != nil && item.secondaryLabel != "Reveal in Finder" { h.append(("Reveal in Finder", "⇧⌘F")) }
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
        personalSlashCache = nil
        rootTranslation = nil
        rescanApps()
    }

    func didShow() {
        if isRoot {
            projects = ProjectScanner.scan(root: config.workspacesRoot)
            slashCache = [:]
            personalSlashCache = nil
            rescanApps()
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
        if case .translate(let t) = screen { copyTranslation(t); return }
        selectedItem?.primary()
    }

    func performSecondary() {
        if case .run(let run) = screen { continueInTerminal(run); return }
        if case .output(let run) = screen { copy(run.output, label: "prompt"); return }
        if case .translate(let t) = screen { swapLanguages(t); return }
        guard let item = selectedItem else { return }
        (item.secondary ?? item.primary)()
    }

    func showActions() {
        if case .translate(let t) = screen { push(.actions(title: "Translate To", items: languageItems(t))); return }
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
            case .run, .output, .translate: return true
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
        case "f" where flags.contains(.shift):
            if let url = selectedItem?.file { reveal(url) }
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
        case .sessions(let p): items = sessionItems(p)
        case .argument(let ext, let project, let values): items = argumentItems(ext, project, values)
        case .output: items = []
        case .slash(let cmd, let project): items = slashArgumentItems(cmd, project)
        case .apps(let running): items = appListItems(runningOnly: running)
        case .translate(let t): items = []; t.update(query)
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

        if let prefix = ["translate ", "tr "].first(where: { query.lowercased().hasPrefix($0) }) {
            out.append(translateItem(String(query.dropFirst(prefix.count))))
            out += commandItems().filter { Fuzzy.score(q, $0.title) != nil }
            return out
        }

        if q.isEmpty {
            out += runs.prefix(3).map(runItem).map { var i = $0; i.section = "Recent Runs"; return i }
            out += sortedProjects().map(projectItem)
            out += commandItems()
            return out
        }

        let projectMatches = projects.compactMap { p in Fuzzy.score(q, p.name).map { (p, $0) } }
            .sorted { $0.1 > $1.1 }
        // Scattered matches with big gaps (score ≤ 0) are noise when the query is a prompt for an agent.
        let appMatches = config.applications.isEnabled ? matchApps(q, in: visibleApps).filter { $0.1 > 0 }.prefix(6) : []
        let running = appMatches.isEmpty ? [:] : AppControl.running()
        let projectItems = projectMatches.map { projectItem($0.0) }
        let appItems = appMatches.map { appItem($0.0, running: running[$0.0.url.path]) }
        // The section with the best match goes first, so "slack" opens Slack and "summonbar" the project.
        let matches = (appMatches.first?.1 ?? .min) > (projectMatches.first?.1 ?? .min)
            ? appItems + projectItems : projectItems + appItems
        let asks = askItems(q)
        let found = matches + filter(contextProject.map { project in
            extensions.map { extensionItem($0, project: project, showProject: true) }
                + slashItems(project, showProject: true, includePersonal: true)
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
            actions: { [unowned self] in projectActions(p) }, file: p.url)
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
        out.append(ListItem(id: "u:sessions", section: "Project", title: "Agent Sessions", subtitle: "Claude Code and Codex history here",
                            icon: "clock.arrow.circlepath", tint: .purple, primary: { [unowned self] in openSessions(p) }))
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
        // Typing `/name args` (or `$name args`) puts the matching commands and skills first,
        // personal ones included.
        if prompt.hasPrefix("/") || prompt.hasPrefix("$") {
            let parts = prompt.dropFirst().split(separator: " ", maxSplits: 1)
            let token = parts.first.map(String.init) ?? ""
            let args = parts.count > 1 ? String(parts[1]) : ""
            let matches = slashCommands(p, includePersonal: true).filter { token.isEmpty || Fuzzy.score(token, $0.name) != nil }
            out.insert(contentsOf: matches.compactMap { slashItem($0, p, args: args) }, at: 0)
        } else {
            out += slashItems(p)
        }
        out += utilityItems(p)
        if agents.isEmpty {
            out.insert(ListItem(id: "noagents", section: "Run Here", title: "No coding agents found on PATH",
                                subtitle: "Install claude, codex, pi, omp, gemini, opencode, cursor-agent or aider, then ⌘R",
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
            ListItem(id: "c:sessions", section: "Commands", title: "Agent Sessions",
                     subtitle: "Claude Code and Codex history, terminal sessions included",
                     icon: "clock.arrow.circlepath", tint: .purple, primary: { [unowned self] in openSessions(nil) }),
            ListItem(id: "c:translate", section: "Commands", title: "Translate", subtitle: "Or type “tr ” and the text",
                     icon: "character.bubble", tint: .indigo, primary: { [unowned self] in openTranslator() }),
            ListItem(id: "c:apps", section: "Commands", title: "Applications", subtitle: "\(visibleApps.count) installed",
                     icon: "square.grid.2x2", tint: .blue, primary: { [unowned self] in push(.apps(running: false)) }),
            ListItem(id: "c:running", section: "Commands", title: "Running Applications", subtitle: "Switch to, hide or quit apps",
                     icon: "app.badge.checkmark", tint: .green, primary: { [unowned self] in push(.apps(running: true)) }),
            ListItem(id: "c:quitall", section: "Commands", title: "Quit All Applications", subtitle: "Everything with a Dock icon except Finder",
                     icon: "xmark.app", tint: .red, primary: { [unowned self] in confirmQuitAll() }),
            ListItem(id: "c:workspaces", section: "Commands", title: "Open Workspaces Folder", icon: "folder",
                     primary: { [unowned self] in NSWorkspace.shared.open(config.workspacesRoot); finish() }),
            ListItem(id: "c:extensions", section: "Commands", title: "Open Extensions Folder",
                     subtitle: "\(extensions.count) extensions in \(ExtensionCatalog.directory.tildePath)", icon: "puzzlepiece.extension",
                     primary: { [unowned self] in NSWorkspace.shared.open(ExtensionCatalog.directory); finish() }),
            ListItem(id: "c:reload", section: "Commands", title: "Reload Projects & Config", icon: "arrow.clockwise", accessory: "⌘R",
                     primary: { [unowned self] in reloadAndReport() }),
            ListItem(id: "c:settings", section: "Commands", title: "Settings", subtitle: "Hotkey, folders, terminal, agents",
                     icon: "gearshape", accessory: "⌘,", primary: { [unowned self] in finish(); openSettings() }),
            ListItem(id: "c:shortcuts", section: "Commands", title: "Keyboard Shortcuts", subtitle: "Every shortcut Summonbar knows",
                     icon: "keyboard", primary: { [unowned self] in finish(); openShortcuts() }),
            ListItem(id: "c:config", section: "Commands", title: "Edit Config File", subtitle: Config.fileURL.tildePath,
                     icon: "doc.text", primary: { [unowned self] in openConfig() }),
            ListItem(id: "c:login", section: "Commands", title: loginEnabled ? "Disable Launch at Login" : "Enable Launch at Login",
                     icon: "power", primary: { [unowned self] in toggleLaunchAtLogin() }),
            updateItem(),
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

    private func startRun(_ agent: Agent, _ project: Project, _ prompt: String, display: String? = nil) {
        markUsed(project)
        let run = AgentRun(agent: agent, project: project)
        run.onChange = { [weak self] in self?.runDidChange() }
        runs.insert(run, at: 0)
        push(.run(run))
        run.send(prompt, display: display)
    }

    private func sendFollowUp(_ run: AgentRun) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !run.deniedRules.isEmpty { allowAndRetry(run); return }
        guard !text.isEmpty else { return }
        guard run.canFollowUp else {
            flash(run.isRunning ? "Wait for the agent to finish, or ⌘. to stop" : "Continue this one in the terminal with ⌘T")
            return
        }
        query = ""
        // A session opened from Agent Sessions only becomes a run once it's continued.
        runs.removeAll { $0 === run }
        runs.insert(run, at: 0)
        run.send(text)
    }

    func allowAndRetry(_ run: AgentRun) {
        guard run.canFollowUp else { return }
        runs.removeAll { $0 === run }
        runs.insert(run, at: 0)
        run.allowAndRetry()
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

    // MARK: - Agent sessions

    private func openSessions(_ project: Project?) {
        push(.sessions(project))
        sessionScan?.cancel()
        sessionScan = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { SessionScanner.scan() }.value
            guard let self, !Task.isCancelled else { return }
            sessions = found
            sessionScan = nil
            if case .sessions = screen { refresh() }
        }
    }

    private func sessionItems(_ project: Project?) -> [ListItem] {
        let list = project.map { p in sessions.filter { $0.cwd.standardizedFileURL == p.url.standardizedFileURL } } ?? sessions
        let q = query.trimmingCharacters(in: .whitespaces)
        // Titles and folders both match, so "summonbar" finds that project's sessions. Titles are whole
        // sentences, so scattered matches with big gaps (score ≤ 0) are noise.
        let matches = q.isEmpty ? list : list.compactMap { s in
            [Fuzzy.score(q, s.title), Fuzzy.score(q, projectName(at: s.cwd))].compactMap { $0 }.max().map { (s, $0) }
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        if matches.isEmpty {
            let scanning = sessionScan != nil
            return [ListItem(id: "ss:none", section: "Agent Sessions",
                             title: scanning ? "Reading sessions…" : q.isEmpty ? "No sessions yet" : "No matching sessions",
                             subtitle: scanning ? nil : "From ~/.claude/projects and ~/.codex/sessions",
                             icon: scanning ? "hourglass" : "tray", primary: {})]
        }
        return matches.map(sessionItem)
    }

    private func sessionItem(_ s: AgentSession) -> ListItem {
        let agent = agents.first { $0.id == s.agentId }
        let spec = AgentCatalog.specs.first { $0.id == s.agentId }
        let name = spec?.name ?? s.agentId
        let missing = { [unowned self] in flash("\(name) isn't on PATH") }
        return ListItem(
            id: "ss:\(s.id)", section: daySection(s.updated), title: s.title,
            subtitle: "\(name) · \(projectName(at: s.cwd))", icon: spec?.icon ?? "bubble.left", tint: .purple,
            accessory: relativeDate(s.updated),
            primaryLabel: "Open Session", primary: agent.map { a in { [unowned self] in openSession(s, a) } } ?? missing,
            secondaryLabel: "Resume in \(config.terminalName)",
            secondary: agent.map { a in { [unowned self] in resumeInTerminal(s, a) } } ?? missing,
            actions: { [unowned self] in
                [
                    ListItem(id: "ssa:term", section: s.title, title: "Resume in \(config.terminalName)", icon: "terminal", tint: .green,
                             primary: agent.map { a in { [unowned self] in resumeInTerminal(s, a) } } ?? missing),
                    ListItem(id: "ssa:id", section: s.title, title: "Copy Session ID", subtitle: s.sessionId, icon: "number",
                             primary: { [unowned self] in copy(s.sessionId, label: "session ID") }),
                    ListItem(id: "ssa:file", section: s.title, title: "Reveal Transcript in Finder", subtitle: s.file.tildePath,
                             icon: "doc.text.magnifyingglass",
                             primary: { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([s.file]); finish() }),
                    ListItem(id: "ssa:project", section: s.title, title: "Open Folder in \(config.editor)", subtitle: s.cwd.tildePath,
                             icon: "chevron.left.forwardslash.chevron.right", tint: .blue,
                             primary: { [unowned self] in TerminalLauncher.openInEditor(s.cwd, editor: config.editor); finish() }),
                ]
            })
    }

    /// Shows what was said so far; ↵ there sends a follow-up that resumes the same session.
    private func openSession(_ s: AgentSession, _ agent: Agent) {
        if let run = runs.first(where: { $0.agentId == s.agentId && $0.sessionId == s.sessionId }) {
            push(.run(run))
            return
        }
        Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) { SessionScanner.transcript(s) }.value
            guard let self, case .sessions = screen else { return }
            let run = AgentRun(session: s, agent: agent, project: project(at: s.cwd), entries: entries)
            run.onChange = { [weak self] in self?.runDidChange() }
            push(.run(run))
            // It can still be read when its folder is gone, just not continued.
            if !FileManager.default.fileExists(atPath: s.cwd.path) { flash("\(s.cwd.tildePath) no longer exists") }
        }
    }

    private func resumeInTerminal(_ s: AgentSession, _ agent: Agent) {
        guard folderExists(s.cwd) else { return }
        TerminalLauncher.open(command: agent.interactiveCommand(prompt: nil, resume: s.sessionId), in: s.cwd, terminal: config.terminal)
        finish()
    }

    private func folderExists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        flash("\(url.tildePath) no longer exists")
        return false
    }

    private func project(at url: URL) -> Project {
        projects.first { $0.url.standardizedFileURL == url.standardizedFileURL } ?? ProjectScanner.make(url, root: config.workspacesRoot)
    }

    private func projectName(at url: URL) -> String {
        projects.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.name ?? url.tildePath
    }

    private func daySection(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return "This Week" }
        return "Earlier"
    }

    // MARK: - Applications

    private var visibleApps: [InstalledApp] { apps.filter { !config.applications.isHidden($0) } }

    private func rescanApps() {
        let directories = config.applications.directoryURLs
        appScan?.cancel()
        appScan = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { AppScanner.scan(extraDirectories: directories) }.value
            guard let self, !Task.isCancelled, found != apps else { return }
            apps = found
            refresh()
        }
    }

    private func runningAppsDidChange() {
        switch screen {
        case .root where !query.isEmpty, .apps: refresh()
        default: break
        }
    }

    /// Matches name, file name and alias; apps opened from here rank higher.
    private func matchApps(_ q: String, in list: [InstalledApp]) -> [(InstalledApp, Int)] {
        let settings = config.applications
        return list.compactMap { app -> (InstalledApp, Int)? in
            guard let best = app.matchScore(q, alias: settings.alias(app)) else { return nil }
            return (app, best + (appUsage[app.key] != nil ? 100 : 0))
        }.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : (appUsage[a.0.key] ?? .distantPast) > (appUsage[b.0.key] ?? .distantPast)
        }
    }

    private func appListItems(runningOnly: Bool) -> [ListItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let running = AppControl.running()
        let list: [InstalledApp]
        if runningOnly {
            // Include apps outside the scanned folders, e.g. one opened from ~/Downloads.
            list = AppControl.quittable().compactMap(\.bundleURL).map { url in
                apps.first { $0.url.path == url.path } ?? AppScanner.make(url)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else {
            list = visibleApps
        }
        let ordered = q.isEmpty ? list : matchApps(q, in: list).map(\.0)
        return ordered.map { app in
            guard runningOnly, let process = running[app.url.path] else { return appItem(app, running: running[app.url.path]) }
            return runningAppItem(app, process)
        }
    }

    private func appItem(_ app: InstalledApp, running: NSRunningApplication?) -> ListItem {
        let settings = config.applications
        let accessory = [running != nil ? "running" : nil, settings.hotkey(app).map(HotKey.describe)]
            .compactMap { $0 }.joined(separator: " · ")
        return ListItem(
            id: "app:" + app.id, section: "Applications", title: app.name, subtitle: settings.alias(app),
            icon: app.url.path, accessory: accessory.isEmpty ? nil : accessory,
            primaryLabel: running == nil ? "Open" : "Switch To", primary: { [unowned self] in openApp(app) },
            secondaryLabel: "Reveal in Finder", secondary: { [unowned self] in reveal(app.url) },
            actions: { [unowned self] in appActions(app) }, file: app.url)
    }

    /// In Running Applications ↵ quits, like Raycast's Quit Applications.
    private func runningAppItem(_ app: InstalledApp, _ process: NSRunningApplication) -> ListItem {
        ListItem(
            id: "app:" + app.id, section: "Running Applications", title: app.name,
            subtitle: process.isHidden ? "hidden" : nil, icon: app.url.path, accessory: process.isActive ? "frontmost" : nil,
            primaryLabel: "Quit", primary: { [unowned self] in quit(app, process) },
            secondaryLabel: "Switch To", secondary: { [unowned self] in openApp(app) },
            actions: { [unowned self] in appActions(app) }, file: app.url)
    }

    private func appActions(_ app: InstalledApp) -> [ListItem] {
        let section = app.name
        let process = AppControl.running()[app.url.path]
        var out = [
            ListItem(id: "aa:open", section: section, title: process == nil ? "Open" : "Switch To", icon: "arrow.up.forward.app",
                     tint: .blue, primary: { [unowned self] in openApp(app) }),
        ]
        if let process {
            out += [
                ListItem(id: "aa:hide", section: section, title: process.isHidden ? "Unhide" : "Hide", icon: "eye.slash",
                         primary: { [unowned self] in
                             _ = process.isHidden ? process.unhide() : process.hide()
                             closeActions()
                         }),
                ListItem(id: "aa:quit", section: section, title: "Quit", subtitle: "The app may ask to save changes",
                         icon: "xmark.circle", tint: .orange, primary: { [unowned self] in quit(app, process) }),
                ListItem(id: "aa:restart", section: section, title: "Restart", icon: "arrow.clockwise", tint: .orange,
                         primary: { [unowned self] in restart(app, process) }),
                ListItem(id: "aa:force", section: section, title: "Force Quit", subtitle: "Unsaved changes are lost",
                         icon: "bolt.circle", tint: .red, primary: { [unowned self] in
                             confirm("Force Quit \(app.name)?", "Force Quit \(app.name)", icon: "bolt.circle") { [unowned self] in
                                 closeActions()
                                 flash(process.forceTerminate() ? "Force quit \(app.name)" : "Couldn't force quit \(app.name)")
                             }
                         }),
            ]
        }
        out += [
            ListItem(id: "aa:finder", section: section, title: "Reveal in Finder", icon: "finder",
                     primary: { [unowned self] in reveal(app.url) }),
            ListItem(id: "aa:path", section: section, title: "Copy Path", subtitle: app.url.tildePath, icon: "doc.on.doc",
                     primary: { [unowned self] in copy(app.url.path, label: app.url.tildePath) }),
        ]
        if let bundleId = app.bundleId {
            out.append(ListItem(id: "aa:bundle", section: section, title: "Copy Bundle Identifier", subtitle: bundleId,
                                icon: "number", primary: { [unowned self] in copy(bundleId, label: bundleId) }))
        }
        out += [
            ListItem(id: "aa:configure", section: section, title: "Set Alias or Hotkey…", subtitle: "Settings › Applications",
                     icon: "keyboard", tint: .purple, primary: { [unowned self] in finish(); openApplicationSettings(app) }),
            ListItem(id: "aa:hidden", section: section, title: "Hide from Search", subtitle: "Show it again in Settings › Applications",
                     icon: "eye.slash", primary: { [unowned self] in hideFromSearch(app) }),
        ]
        if AppControl.canTrash(app) {
            out.append(ListItem(
                id: "aa:trash", section: section, title: "Move to Trash", subtitle: app.url.tildePath, icon: "trash", tint: .red,
                primary: { [unowned self] in
                    guard AppControl.running()[app.url.path] == nil else { flash("Quit \(app.name) first"); return }
                    confirm("Move \(app.name) to Trash?", "Move \(app.name) to Trash", icon: "trash") { [unowned self] in trash(app) }
                }))
        }
        return out
    }

    /// Opens or focuses an app from its global hotkey; pressing it again while the app is frontmost hides it.
    func toggleApp(key: String) {
        let url = apps.first { $0.key == key }?.url
            ?? (key.hasPrefix("/") ? URL(fileURLWithPath: key) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: key))
        guard let url else { NSSound.beep(); return }
        if let process = AppControl.running()[url.path], process.isActive {
            process.hide()
        } else {
            markUsed(appKey: key)
            AppControl.open(url)
        }
    }

    private func openApp(_ app: InstalledApp) {
        markUsed(appKey: app.key)
        AppControl.open(app.url)
        finish()
    }

    private func quit(_ app: InstalledApp, _ process: NSRunningApplication) {
        closeActions()
        flash(process.terminate() ? "Quitting \(app.name)…" : "\(app.name) can't be quit")
    }

    private func restart(_ app: InstalledApp, _ process: NSRunningApplication) {
        closeActions()
        flash("Restarting \(app.name)…")
        Task { [weak self] in
            if await !AppControl.restart(process, at: app.url) { self?.flash("\(app.name) didn't quit — it may be asking to save") }
        }
    }

    private func confirmQuitAll() {
        let targets = AppControl.quittable()
        guard !targets.isEmpty else { flash("No apps to quit"); return }
        let names = targets.compactMap(\.localizedName).sorted().joined(separator: ", ")
        confirm("Quit \(targets.count) Applications?", "Quit \(targets.count) Applications", icon: "xmark.app", subtitle: names) { [unowned self] in
            let asked = targets.filter { $0.terminate() }.count
            closeActions()
            flash("Asked \(asked) app\(asked == 1 ? "" : "s") to quit")
        }
    }

    private func trash(_ app: InstalledApp) {
        NSWorkspace.shared.recycle([app.url]) { _, error in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                closeActions()
                if let error {
                    flash("Couldn't move \(app.name) to Trash: \(error.localizedDescription)")
                } else {
                    apps.removeAll { $0.id == app.id }
                    refresh()
                    flash("Moved \(app.name) to Trash")
                }
            }
        }
    }

    private func hideFromSearch(_ app: InstalledApp) {
        var updated = Config.load()
        updated.applications.hidden = (updated.applications.hidden ?? []).filter { $0 != app.key } + [app.key]
        do {
            try updated.save()
        } catch {
            flash("Couldn't save config.json: \(error.localizedDescription)")
            return
        }
        config = updated
        closeActions()
        flash("\(app.name) is hidden — show it again in Settings › Applications")
    }

    /// A one-item menu that runs `action` only when picked; esc cancels.
    private func confirm(_ title: String, _ label: String, icon: String, subtitle: String? = nil, action: @escaping () -> Void) {
        push(.actions(title: title, items: [
            ListItem(id: "confirm", section: title, title: label, subtitle: subtitle, icon: icon, tint: .red,
                     primaryLabel: "Confirm", primary: action),
            ListItem(id: "cancel", section: title, title: "Cancel", icon: "arrow.uturn.backward",
                     primaryLabel: "Cancel", primary: { [unowned self] in back() }),
        ]))
    }

    /// Leaves action menus and confirmations, back to the list they were opened from.
    private func closeActions() {
        while frames.count > 1, case .actions = screen { back() }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        finish()
    }

    private func markUsed(appKey: String) {
        appUsage[appKey] = Date()
        Store.saveUsage(appUsage, apps: true)
    }

    // MARK: - Translate

    private func translateItem(_ text: String) -> ListItem {
        let t = rootTranslation ?? Translation(config: config.translation)
        if rootTranslation == nil {
            t.onChange = { [weak self] in
                guard let self, case .root = screen else { return }
                refresh()
            }
            rootTranslation = t
        }
        t.update(text)
        let open = { [unowned self] in openTranslator(text, target: t.chosenTarget) }
        guard !t.input.isEmpty else {
            return ListItem(id: "tr", section: "Translate", title: "Translate: type the text after “tr ”",
                            subtitle: "To \(Language.name(t.target)) · ⌘K for another language", icon: "character.bubble", tint: .indigo,
                            primaryLabel: "Open Translator", primary: open, actions: { [unowned self] in languageItems(t) })
        }
        let title: String
        if case .failed(let message) = t.status { title = message }
        else { title = t.output.isEmpty ? "Translating…" : t.output }
        return ListItem(id: "tr", section: "Translate", title: title, subtitle: t.direction, icon: "character.bubble", tint: .indigo,
                        accessory: t.isTranslating && !t.output.isEmpty ? "translating…" : nil,
                        primaryLabel: "Copy Translation", primary: { [unowned self] in copyTranslation(t) },
                        secondaryLabel: "Open Translator", secondary: open,
                        actions: { [unowned self] in languageItems(t) })
    }

    private func openTranslator(_ text: String = "", target: String? = nil) {
        let t = Translation(config: config.translation, target: target)
        t.onChange = { [weak self] in self?.objectWillChange.send() }
        push(.translate(t), query: text)
    }

    /// Copies the translation and hides the launcher, so it can be pasted right away. After a failure, tries again.
    private func copyTranslation(_ t: Translation) {
        if case .failed = t.status { t.choose(t.chosenTarget); refresh(); return }
        guard !t.isTranslating else { flash("Still translating…"); return }
        guard !t.output.isEmpty else { flash("Type the text to translate first"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.output, forType: .string)
        finish()
    }

    /// Translates the result back into the language it came from.
    private func swapLanguages(_ t: Translation) {
        guard !t.isTranslating, !t.output.isEmpty, let source = t.source else { return }
        t.choose(source)
        setQuery(t.output)
    }

    private func languageItems(_ t: Translation) -> [ListItem] {
        let config = config.translation
        let automatic = config.fallback.map { "\(Language.name(config.target)), or \(Language.name($0)) for \(Language.name(config.target)) text" }
            ?? Language.name(config.target)
        let pick: (String?) -> () -> Void = { code in { [unowned self] in t.choose(code); closeActions() } }
        return [ListItem(id: "lang:auto", section: "Translate To", title: "Automatic", subtitle: automatic, icon: "wand.and.stars",
                         tint: .indigo, accessory: t.chosenTarget == nil ? "current" : nil, primaryLabel: "Choose", primary: pick(nil))]
            + Language.all.map { language in
                ListItem(id: "lang:\(language.code)", section: "Translate To", title: language.name, subtitle: language.code,
                         icon: "globe", tint: .indigo, accessory: t.chosenTarget == language.code ? "current" : nil,
                         primaryLabel: "Choose", primary: pick(language.code))
            }
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
            },
            file: ext.url)
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

    // MARK: - Claude Code commands and skills, and Agent Skills

    /// Project commands and skills; personal ones from `~/.claude` and `~/.agents` only when asked, since they'd
    /// crowd every project's list. A project item wins over a personal one with the same name.
    private func slashCommands(_ p: Project, includePersonal: Bool = false) -> [SlashCommand] {
        let project = slashCache[p.url] ?? SlashCommandScanner.scan(project: p.url)
        slashCache[p.url] = project
        guard includePersonal else { return project }
        let personal = personalSlashCache ?? SlashCommandScanner.scanPersonal()
        personalSlashCache = personal
        let taken = Set(project.map(\.name))
        return project + personal.filter { !taken.contains($0.name) }
    }

    private func slashItems(_ p: Project, showProject: Bool = false, includePersonal: Bool = false) -> [ListItem] {
        slashCommands(p, includePersonal: includePersonal).compactMap { slashItem($0, p, showProject: showProject) }
    }

    private func slashItem(_ cmd: SlashCommand, _ p: Project, args: String = "", showProject: Bool = false) -> ListItem? {
        guard let agent = agent(for: cmd) else { return nil }
        let prompt = cmd.title(args: args)
        let run = { [unowned self] (agent: Agent) in startRun(agent, p, cmd.prompt(for: agent, args: args), display: prompt) }
        let wantsArguments = args.isEmpty && cmd.argumentHint != nil
        return ListItem(
            id: "s:\(cmd.id)",
            section: (cmd.isPersonal ? "Personal " : "") + (cmd.isAgentSkill ? "Agent " : cmd.isPersonal ? "" : "Claude ")
                + (cmd.kind == .skill ? "Skills" : "Commands"),
            title: prompt,
            subtitle: showProject ? "in \(p.name) · ⌘K on a project to pick another" : cmd.description,
            icon: cmd.kind == .skill ? "wand.and.stars" : "slash.circle", tint: .purple, accessory: args.isEmpty ? cmd.argumentHint : nil,
            primaryLabel: wantsArguments ? "Add Arguments" : "Ask \(agent.name)",
            primary: { [unowned self] in wantsArguments ? push(.slash(cmd, p)) : run(agent) },
            secondaryLabel: "Open in \(config.terminalName)",
            secondary: { [unowned self] in launch(agent, p, prompt: cmd.prompt(for: agent, args: args)) },
            actions: { [unowned self] in
                [
                    ListItem(id: "sa:args", section: cmd.invocation, title: "Run with Arguments…", icon: "text.cursor", tint: .purple,
                             primary: { [unowned self] in push(.slash(cmd, p)) }),
                    ListItem(id: "sa:term", section: cmd.invocation, title: "Open in \(config.terminalName)", icon: "terminal", tint: .green,
                             primary: { [unowned self] in launch(agent, p, prompt: cmd.prompt(for: agent, args: args)) }),
                ]
                // An Agent Skill works with any agent, not just the default one.
                + (cmd.isAgentSkill ? agents.dropFirst() : []).map { other in
                    ListItem(id: "sa:ask:\(other.id)", section: cmd.invocation, title: "Ask \(other.name)", icon: other.icon,
                             tint: .orange, primary: { run(other) })
                }
                + [

                    ListItem(id: "sa:edit", section: cmd.invocation, title: "Edit in \(config.editor)", subtitle: cmd.url.tildePath,
                             icon: "chevron.left.forwardslash.chevron.right", tint: .blue,
                             primary: { [unowned self] in TerminalLauncher.openInEditor(cmd.url, editor: config.editor); finish() }),
                    ListItem(id: "sa:finder", section: cmd.invocation, title: "Reveal in Finder", icon: "finder",
                             primary: { [unowned self] in NSWorkspace.shared.activateFileViewerSelecting([cmd.url]); finish() }),
                ]
            },
            file: cmd.url)
    }

    private func slashArgumentItems(_ cmd: SlashCommand, _ p: Project) -> [ListItem] {
        let args = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var item = slashItem(cmd, p, args: args) else {
            return [ListItem(id: "s:noagent", section: cmd.invocation,
                             title: cmd.isAgentSkill ? "No coding agents found on PATH" : "Claude Code isn't on PATH",
                             icon: "exclamationmark.triangle", tint: .orange, primary: {})]
        }
        // Here ↵ always runs, even with no arguments typed.
        item.section = cmd.argumentHint ?? "Arguments"
        item.subtitle = cmd.description
        item.primary = { [unowned self] in
            if let agent = agent(for: cmd) { startRun(agent, p, cmd.prompt(for: agent, args: args), display: cmd.title(args: args)) }
        }
        item.actions = nil
        return [item]
    }

    private func reloadAndReport() {
        reload()
        refresh()
        flash("Reloaded \(projects.count) projects, \(agents.count) agents, \(extensions.count) extensions, \(visibleApps.count) apps")
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

    private func updateItem() -> ListItem {
        let updater = Updater.shared
        if let release = updater.available {
            return ListItem(id: "c:update", section: "Commands", title: "Update to Summonbar \(release.version)",
                            subtitle: "You have \(updater.currentVersion) · relaunches when done", icon: "arrow.down.circle",
                            tint: .green, primaryLabel: "Update", primary: { [unowned self] in finish(); updateSummonbar() })
        }
        return ListItem(id: "c:update", section: "Commands", title: "Check for Updates",
                        subtitle: updater.isBusy ? "Checking…" : "Summonbar \(updater.currentVersion)",
                        icon: "arrow.triangle.2.circlepath", primary: { [unowned self] in finish(); updateSummonbar() })
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
