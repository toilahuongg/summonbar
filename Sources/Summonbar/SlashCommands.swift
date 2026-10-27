import Foundation

/// A Claude Code custom command (`.claude/commands/*.md`) or skill
/// (`.claude/skills/<name>/SKILL.md`) that a project or `~/.claude` defines,
/// or an Agent Skill in `.agents/skills` or `~/.agents/skills`.
/// Running one sends `/name args` to Claude Code. An `.agents` skill runs with any
/// agent: Codex gets `$name args`, the others get the skill's instructions inlined.
struct SlashCommand: Identifiable {
    enum Kind { case command, skill }

    let kind: Kind
    let name: String
    let description: String?
    let argumentHint: String?
    let url: URL
    /// From `~/.claude` or `~/.agents` rather than the project.
    let isPersonal: Bool
    /// From `.agents/skills`, which Codex reads and Claude Code doesn't.
    var isAgentSkill = false

    var id: String { url.path }
    var invocation: String { (isAgentSkill ? "$" : "/") + name }

    /// What the user sees: `/name args` or `$name args`.
    func title(args: String) -> String {
        args.isEmpty ? invocation : "\(invocation) \(args)"
    }

    /// What `agent` is sent. Agents that don't load `.agents` skills get the SKILL.md
    /// body inlined, so the run looks the same but works everywhere.
    func prompt(for agent: Agent, args: String) -> String {
        guard isAgentSkill, agent.id != "codex",
              let text = try? String(contentsOf: url, encoding: .utf8) else { return title(args: args) }
        let body = SlashCommandScanner.frontMatter(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
        let skill = """
        Use the "\(name)" skill below. Paths in it are relative to \(url.deletingLastPathComponent().path).

        <skill name="\(name)">
        \(body)
        </skill>
        """
        return args.isEmpty ? skill : skill + "\n\n" + args
    }
}

enum SlashCommandScanner {
    static func scan(project: URL) -> [SlashCommand] {
        scan(root: project, personal: false)
    }

    /// The user's own commands and skills, available in every project.
    static func scanPersonal() -> [SlashCommand] {
        scan(root: FileManager.default.homeDirectoryForCurrentUser, personal: true)
    }

    /// `.claude` wins over `.agents` for the same name, which also hides the copies
    /// that skill installers symlink into both.
    private static func scan(root: URL, personal: Bool) -> [SlashCommand] {
        let claude = root.appendingPathComponent(".claude", isDirectory: true)
        let found = commands(in: claude.appendingPathComponent("commands", isDirectory: true), personal: personal)
            + skills(in: claude.appendingPathComponent("skills", isDirectory: true), personal: personal)
        let taken = Set(found.map(\.name))
        let agents = skills(in: root.appendingPathComponent(".agents/skills", isDirectory: true), personal: personal)
            .filter { !taken.contains($0.name) }
            .map { var skill = $0; skill.isAgentSkill = true; return skill }
        return (found + agents).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every `.md` file, subfolders included; the file name is the command name.
    private static func commands(in dir: URL, personal: Bool) -> [SlashCommand] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "md",
                  let text = read(url) else { return nil }
            let (meta, body) = frontMatter(text)
            return SlashCommand(kind: .command, name: url.deletingPathExtension().lastPathComponent,
                                description: meta["description"] ?? firstLine(body),
                                argumentHint: meta["argument-hint"], url: url, isPersonal: personal)
        }
    }

    private static func skills(in dir: URL, personal: Bool) -> [SlashCommand] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent("SKILL.md")
            guard let text = read(url) else { return nil }
            let (meta, _) = frontMatter(text)
            if meta["user-invocable"]?.lowercased() == "false" { return nil }
            return SlashCommand(kind: .skill, name: meta["name"] ?? folder.lastPathComponent,
                                description: meta["description"], argumentHint: meta["argument-hint"], url: url,
                                isPersonal: personal)
        }
    }

    private static func read(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16_384)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Flat `key: value` pairs from a leading `---` block. Folded values (`>`, `|`)
    /// are joined from their indented lines; that's all commands and skills use.
    fileprivate static func frontMatter(_ text: String) -> (meta: [String: String], body: Substring) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], Substring(text)) }

        var meta: [String: String] = [:]
        var folding: String?
        for line in lines[1..<end] {
            if let key = folding, line.first == " " || line.first == "\t" {
                let part = line.trimmingCharacters(in: .whitespaces)
                meta[key] = meta[key].map { $0.isEmpty ? part : $0 + " " + part } ?? part
                continue
            }
            folding = nil
            guard let colon = line.firstIndex(of: ":"), line.first != " " else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { folding = key; value = "" }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            meta[key] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (meta.filter { !$0.value.isEmpty }, Substring(body))
    }

    private static func firstLine(_ body: Substring) -> String? {
        body.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .first { !$0.isEmpty }
    }
}
