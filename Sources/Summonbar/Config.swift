import Foundation

struct AgentOverride: Codable {
    /// Extra args for interactive (terminal) sessions.
    var args: [String]?
    /// Extra args for inline (headless) runs inside the launcher.
    var headlessArgs: [String]?
    var disabled: Bool?
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
}

struct Config {
    var workspacesRoot: URL
    var hotkey: String
    var terminal: String
    var editor: String
    var defaultAgent: String
    var gitInitNewProjects: Bool
    var agents: [String: AgentOverride]

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
            agents: defaultAgents.merging(file.agents ?? [:]) { _, user in user }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(template) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    var terminalName: String {
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
