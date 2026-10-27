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
    private var usage = Store.loadUsage()
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    var hidePanel: () -> Void = {}
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
    var runningCount: Int { runs.filter(\.isRunning).count }

    var placeholder: String {
        switch screen {
        case .root: return "Search projects, or ask an agent…"
        case .actions: return "Search actions…"
        case .prompt(let p): return "What should the agent do in \(p.name)?"
        case .run(let run): return run.isRunning ? "\(run.agentName) is working…" : (run.canFollowUp ? "Send a follow-up…" : "This agent can't continue the conversation inline")
        case .runs: return "Search agent runs…"
        }
    }

    var breadcrumb: String? {
        switch screen {
        case .root: return nil
        case .actions(let title, _): return title
        case .prompt(let p): return p.name
        case .run(let run): return "\(run.agentName) · \(run.projectName)"
        case .runs: return "Agent Runs"
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
    }

    func didShow() {
        if isRoot {
            projects = ProjectScanner.scan(root: config.workspacesRoot)
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
        selectedItem?.primary()
    }

    func performSecondary() {
        if case .run(let run) = screen { continueInTerminal(run); return }
        guard let item = selectedItem else { return }
        (item.secondary ?? item.primary)()
    }

    func showActions() {
        guard let item = selectedItem, let actions = item.actions?() else { return }
        push(.actions(title: item.title, items: actions))
    }

    func enterSelected() {
        guard case .root = screen, let item = selectedItem, item.id.hasPrefix("p:"),
              let project = projects.first(where: { "p:" + $0.id == item.id }) else { return }
        push(.prompt(project))
    }

    /// Returns true when the key was handled and should not reach the text field.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let inRun: Bool = { if case .run = screen { return true } else { return false } }()

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
        case ".": if case .run(let run) = screen { run.stop() }; return true
        case ",": openConfig(); return true
        case "r": reload(); refresh(); flash("Reloaded \(projects.count) projects, \(agents.count) agents"); return true
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
        out += matches.isEmpty ? asks + matches : matches + asks
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
                     primary: { [unowned self] in
                         NSPasteboard.general.clearContents()
                         NSPasteboard.general.setString(p.url.path, forType: .string)
                         flash("Copied \(p.url.tildePath)")
                     }),
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
        out += utilityItems(p)
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
            ListItem(id: "c:reload", section: "Commands", title: "Reload Projects & Config", icon: "arrow.clockwise", accessory: "⌘R",
                     primary: { [unowned self] in reload(); refresh(); flash("Reloaded \(projects.count) projects, \(agents.count) agents") }),
            ListItem(id: "c:config", section: "Commands", title: "Edit Config", subtitle: Config.fileURL.tildePath,
                     icon: "gearshape", accessory: "⌘,", primary: { [unowned self] in openConfig() }),
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
