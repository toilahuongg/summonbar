import Foundation

enum OutputFormat {
    /// `claude -p --output-format stream-json`
    case claude
    /// `codex exec --json`
    case codex
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

    /// Command for an interactive session in a terminal.
    func interactiveCommand(prompt: String?, resume: String?) -> [String] {
        var cmd = [binary]
        switch id {
        case "claude":
            cmd += args
            if let resume { cmd += ["--resume", resume] }
            if let prompt { cmd.append(prompt) }
        case "codex":
            if let resume {
                cmd += ["resume", resume]
            } else {
                cmd += args
                if let prompt { cmd.append(prompt) }
            }
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
            var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            if let resume { a += ["--resume", resume] }
            return (a + headlessArgs, prompt)
        case "codex":
            if let resume {
                return (["exec"] + headlessArgs + ["resume", "--json", "--skip-git-repo-check", resume, "-"], prompt)
            }
            return (["exec", "--json", "--skip-git-repo-check"] + headlessArgs + ["-"], prompt)
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
    private struct Spec {
        let id: String, name: String, binary: String, icon: String, format: OutputFormat
    }

    private static let specs: [Spec] = [
        Spec(id: "claude", name: "Claude Code", binary: "claude", icon: "sparkle", format: .claude),
        Spec(id: "codex", name: "Codex", binary: "codex", icon: "hexagon", format: .codex),
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
