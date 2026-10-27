import Foundation

enum OutputFormat {
    /// `claude -p --output-format stream-json`
    case claude
    /// `codex exec --json`
    case codex
    /// `pi -p --mode json`, which omp (Oh My Pi) shares
    case pi
    /// Plain stdout text.
    case plain
}

struct Agent: Identifiable, Hashable {
    let id: String
    let name: String
    let binary: String
    let icon: String
    let format: OutputFormat
    let args: [String]
    let headlessArgs: [String]

    var canResume: Bool { format != .plain }

    /// `--add-dir` for the personal skill folders. Claude Code only reads inside the
    /// project without asking, and a headless run can't ask, so a skill's references
    /// and scripts would be denied. The `=` form keeps the variadic flag off the prompt.
    private static var skillDirArgs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".claude/skills", ".agents/skills"]
            .map { home.appendingPathComponent($0, isDirectory: true).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { "--add-dir=\($0)" }
    }

    /// Command for an interactive session in a terminal.
    func interactiveCommand(prompt: String?, resume: String?) -> [String] {
        var cmd = [binary]
        switch id {
        case "claude":
            cmd += Self.skillDirArgs + args
            if let resume { cmd += ["--resume", resume] }
            if let prompt { cmd.append(prompt) }
        case "codex":
            if let resume {
                cmd += ["resume", resume]
            } else {
                cmd += args
                if let prompt { cmd.append(prompt) }
            }
        case "pi":
            cmd += args
            if let resume { cmd += ["--session", resume] }
            if let prompt { cmd.append(prompt) }
        case "omp":
            cmd += args
            if let resume { cmd += ["--resume", resume] }
            if let prompt { cmd.append(prompt) }
        case "gemini":
            cmd += args
            if let prompt { cmd += ["-i", prompt] }
        case "opencode":
            cmd += args
            if let prompt { cmd += ["--prompt", prompt] }
        default:
            cmd += args
            if let prompt { cmd.append(prompt) }
        }
        return cmd
    }

    /// Arguments for an inline run, plus the text to feed on stdin (if any).
    /// Prompts go through stdin where supported so text starting with `-`
    /// can't be mistaken for a flag.
    func headlessInvocation(prompt: String, resume: String?) -> (args: [String], stdin: String?) {
        switch id {
        case "claude":
            var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"] + Self.skillDirArgs
            if let resume { a += ["--resume", resume] }
            return (a + headlessArgs, prompt)
        case "codex":
            if let resume {
                return (["exec"] + headlessArgs + ["resume", "--json", "--skip-git-repo-check", resume, "-"], prompt)
            }
            return (["exec", "--json", "--skip-git-repo-check"] + headlessArgs + ["-"], prompt)
        case "pi", "omp":
            var a = ["-p", "--mode", "json"]
            if let resume { a += [id == "pi" ? "--session" : "--resume", resume] }
            return (a + headlessArgs, prompt)
        case "gemini":
            return (headlessArgs + ["-p", prompt], nil)
        case "opencode":
            return (["run"] + headlessArgs + [prompt], nil)
        case "cursor-agent":
            return (["-p", "--output-format", "text"] + headlessArgs + [prompt], nil)
        case "aider":
            return (["--message", prompt, "--yes-always", "--no-pretty"] + headlessArgs, nil)
        default:
            return (headlessArgs + [prompt], nil)
        }
    }
}

enum AgentCatalog {
    struct Spec {
        let id: String, name: String, binary: String, icon: String, format: OutputFormat
    }

    /// Every agent Summonbar knows how to drive, installed or not.
    static let specs: [Spec] = [
        Spec(id: "claude", name: "Claude Code", binary: "claude", icon: "sparkle", format: .claude),
        Spec(id: "codex", name: "Codex", binary: "codex", icon: "hexagon", format: .codex),
        Spec(id: "pi", name: "Pi", binary: "pi", icon: "function", format: .pi),
        Spec(id: "omp", name: "Oh My Pi", binary: "omp", icon: "circle.hexagongrid", format: .pi),
        Spec(id: "gemini", name: "Gemini CLI", binary: "gemini", icon: "diamond", format: .plain),
        Spec(id: "cursor-agent", name: "Cursor Agent", binary: "cursor-agent", icon: "cursorarrow.rays", format: .plain),
        Spec(id: "opencode", name: "opencode", binary: "opencode", icon: "chevron.left.forwardslash.chevron.right", format: .plain),
        Spec(id: "aider", name: "Aider", binary: "aider", icon: "wrench.and.screwdriver", format: .plain),
    ]

    /// Agents that are actually installed, default agent first.
    static func detect(config: Config) -> [Agent] {
        let found: [Agent] = specs.compactMap { spec in
            let override = config.agents[spec.id]
            if override?.disabled == true { return nil }
            guard let path = Shell.which(spec.binary) else { return nil }
            return Agent(id: spec.id, name: spec.name, binary: path, icon: spec.icon, format: spec.format,
                         args: override?.args ?? [], headlessArgs: override?.headlessArgs ?? [])
        }
        return found.sorted { a, _ in a.id == config.defaultAgent }
    }
}
