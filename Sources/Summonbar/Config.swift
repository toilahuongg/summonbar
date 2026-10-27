import Foundation

struct AgentOverride: Codable {
    /// Extra args for interactive (terminal) sessions.
    var args: [String]?
    /// Extra args for inline (headless) runs inside the launcher.
    var headlessArgs: [String]?
    var disabled: Bool?
}

/// The `applications` key of config.json. Apps are keyed by bundle id (or path, for apps without one).
struct ApplicationsConfig: Codable {
    /// Show installed apps in the root search.
    var enabled: Bool?
    /// Extra names to search by, e.g. "code" for Visual Studio Code.
    var aliases: [String: String]?
    /// Global hotkeys that open an app, e.g. "ctrl+opt+t".
    var hotkeys: [String: String]?
    /// Apps left out of search.
    var hidden: [String]?
    /// Folders to scan besides /Applications, /System/Applications and ~/Applications.
    var directories: [String]?

    var isEnabled: Bool { enabled ?? true }
    var directoryURLs: [URL] { (directories ?? []).map { URL(fileURLWithPath: Config.expand($0), isDirectory: true) } }

    func alias(_ app: InstalledApp) -> String? { aliases?[app.key].flatMap { $0.isEmpty ? nil : $0 } }
    func hotkey(_ app: InstalledApp) -> String? { hotkeys?[app.key].flatMap { $0.isEmpty ? nil : $0 } }
    func isHidden(_ app: InstalledApp) -> Bool { hidden?.contains(app.key) == true }

    /// Nil when nothing is set, so config.json stays tidy.
    var nonEmpty: ApplicationsConfig? {
        var copy = self
        if copy.aliases?.isEmpty == true { copy.aliases = nil }
        if copy.hotkeys?.isEmpty == true { copy.hotkeys = nil }
        if copy.hidden?.isEmpty == true { copy.hidden = nil }
        if copy.directories?.isEmpty == true { copy.directories = nil }
        let empty = copy.enabled == nil && copy.aliases == nil && copy.hotkeys == nil && copy.hidden == nil && copy.directories == nil
        return empty ? nil : copy
    }
}

/// The `translation` key of config.json, as Google Translate language codes.
struct TranslationConfig: Codable {
    /// What text is translated into.
    var to: String?
    /// Used instead when the text is already in `to`; "" turns that off. Defaults to a system language.
    var alternate: String?

    var target: String { to.flatMap { $0.isEmpty ? nil : $0 } ?? "en" }
    var fallback: String? {
        if let alternate { return alternate.isEmpty ? nil : alternate }
        // The first system language that isn't `to`, else English.
        return Language.preferred.first { !Language.same($0, target) } ?? (Language.same(target, "en") ? nil : "en")
    }
}

/// On-disk shape of ~/.config/summonbar/config.json. Every key is optional.
private struct ConfigFile: Codable {
    var workspacesRoot: String?
    var hotkey: String?
    var terminal: String?
    var editor: String?
    var defaultAgent: String?
    var gitInitNewProjects: Bool?
    var agents: [String: AgentOverride]?
    var extensionDirectories: [String]?
    var applications: ApplicationsConfig?
    var translation: TranslationConfig?
}

struct Config {
    var workspacesRoot: URL
    var hotkey: String
    var terminal: String
    var editor: String
    var defaultAgent: String
    var gitInitNewProjects: Bool
    var agents: [String: AgentOverride]
    /// Extra folders of extension scripts, e.g. a team repo of shared prompts.
    var extensionDirectories: [URL]
    var applications: ApplicationsConfig
    var translation: TranslationConfig

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/summonbar", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("config.json")

    static let defaultAgents: [String: AgentOverride] = [
        "claude": AgentOverride(args: [], headlessArgs: ["--permission-mode", "acceptEdits"]),
        "codex": AgentOverride(args: [], headlessArgs: ["--sandbox", "workspace-write"]),
    ]

    static func load() -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            writeTemplate()
        }
        var file = ConfigFile()
        if let data = try? Data(contentsOf: fileURL) {
            do {
                file = try JSONDecoder().decode(ConfigFile.self, from: data)
            } catch {
                NSLog("Summonbar: invalid config.json, using defaults: \(error)")
            }
        }
        let ghostty = fm.fileExists(atPath: "/Applications/Ghostty.app")
        return Config(
            workspacesRoot: URL(fileURLWithPath: expand(file.workspacesRoot ?? "~/Workspaces"), isDirectory: true),
            hotkey: file.hotkey ?? "cmd+shift+space",
            terminal: file.terminal ?? (ghostty ? "ghostty" : "terminal"),
            editor: file.editor ?? "Visual Studio Code",
            defaultAgent: file.defaultAgent ?? "claude",
            gitInitNewProjects: file.gitInitNewProjects ?? true,
            agents: defaultAgents.merging(file.agents ?? [:]) { _, user in user },
            extensionDirectories: (file.extensionDirectories ?? []).map { URL(fileURLWithPath: expand($0), isDirectory: true) },
            applications: file.applications ?? ApplicationsConfig(),
            translation: file.translation ?? TranslationConfig()
        )
    }

    private static func writeTemplate() {
        let ghostty = FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
        let template = ConfigFile(
            workspacesRoot: "~/Workspaces",
            hotkey: "cmd+shift+space",
            terminal: ghostty ? "ghostty" : "terminal",
            editor: "Visual Studio Code",
            defaultAgent: "claude",
            gitInitNewProjects: true,
            agents: defaultAgents
        )
        try? write(template)
    }

    /// Writes this config back to config.json (used by the Settings window).
    func save() throws {
        try Self.write(ConfigFile(
            workspacesRoot: workspacesRoot.tildePath,
            hotkey: hotkey,
            terminal: terminal,
            editor: editor,
            defaultAgent: defaultAgent,
            gitInitNewProjects: gitInitNewProjects,
            agents: agents,
            extensionDirectories: extensionDirectories.isEmpty ? nil : extensionDirectories.map(\.tildePath),
            applications: applications.nonEmpty,
            translation: translation.to == nil && translation.alternate == nil ? nil : translation
        ))
    }

    private static func write(_ file: ConfigFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    var terminalName: String { Self.terminalName(terminal) }

    static func terminalName(_ terminal: String) -> String {
        switch terminal.lowercased() {
        case "ghostty": return "Ghostty"
        case "iterm", "iterm2": return "iTerm"
        case "warp": return "Warp"
        case "terminal": return "Terminal"
        default: return terminal
        }
    }
}

extension URL {
    /// Path with the home directory collapsed to `~`.
    var tildePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
