import Foundation

/// A conversation saved by Claude Code (`~/.claude/projects`) or Codex (`~/.codex/sessions`),
/// whether it started in a terminal, an editor, or inline in Summonbar.
struct AgentSession: Identifiable, Hashable {
    let agentId: String
    /// The agent's own session id, the one `--resume` / `resume` takes.
    let sessionId: String
    let title: String
    let cwd: URL
    let updated: Date
    let file: URL

    var id: String { "\(agentId):\(sessionId)" }
}

enum SessionScanner {
    /// Newest files only, so opening the list stays quick with years of history.
    static let limit = 300
    private static let chunk = 128 * 1024

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func scan() -> [AgentSession] {
        (claudeSessions() + codexSessions()).sorted { $0.updated > $1.updated }
    }

    // MARK: - Claude Code

    /// `~/.claude/projects/<encoded cwd>/<session id>.jsonl`; subfolders hold subagent transcripts.
    private static func claudeSessions() -> [AgentSession] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let files = folders.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        return newest(files).compactMap { file, updated in
            let (head, tail) = edges(of: file)
            var cwd: String?, prompt: String?, title: String?
            for obj in head {
                if cwd == nil { cwd = obj["cwd"] as? String }
                if prompt == nil, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
                   obj["isSidechain"] as? Bool != true {
                    prompt = claudeText((obj["message"] as? [String: Any])?["content"]).flatMap(promptTitle)
                }
            }
            // A title the user set beats the one Claude Code generated; the latest of each wins.
            for key in ["customTitle", "aiTitle"] where title == nil {
                title = (tail + head).reversed().compactMap { $0[key] as? String }.first { !$0.isEmpty }
            }
            guard let cwd, let label = title ?? prompt else { return nil }
            return AgentSession(agentId: "claude", sessionId: file.deletingPathExtension().lastPathComponent, title: label,
                                cwd: URL(fileURLWithPath: cwd, isDirectory: true), updated: updated, file: file)
        }
    }

    private static func claudeText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        // Tool results come back as user messages; they aren't something the user typed.
        guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
    }

    // MARK: - Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, named by `session_index.jsonl` when Codex has a name for it.
    private static func codexSessions() -> [AgentSession] {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
        let names = codexNames()
        return newest(files).compactMap { file, updated in
            let head = edges(of: file).head
            guard let meta = head.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
                  let id = meta["id"] as? String, let cwd = meta["cwd"] as? String else { return nil }
            let prompt = head.lazy.compactMap { obj -> String? in
                guard obj["type"] as? String == "response_item", let payload = obj["payload"] as? [String: Any],
                      payload["role"] as? String == "user" else { return nil }
                let blocks = payload["content"] as? [[String: Any]] ?? []
                return blocks.lazy.compactMap { $0["text"] as? String }.compactMap(promptTitle).first
            }.first
            guard let label = names[id] ?? prompt else { return nil }
            return AgentSession(agentId: "codex", sessionId: id, title: label,
                                cwd: URL(fileURLWithPath: cwd, isDirectory: true), updated: updated, file: file)
        }
    }

    private static func codexNames() -> [String: String] {
        let url = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var names: [String: String] = [:]
        for obj in lines(data) {
            if let id = obj["id"] as? String, let name = obj["thread_name"] as? String, !name.isEmpty { names[id] = name }
        }
        return names
    }

    // MARK: - Transcript

    /// What was said, for showing a session before continuing it. Tool calls and their output are left out.
    static func transcript(_ session: AgentSession, limit: Int = 200) -> [Entry] {
        guard let data = try? Data(contentsOf: session.file) else { return [] }
        var entries: [Entry] = []
        for obj in lines(data) {
            if session.agentId == "claude" {
                guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                      let message = obj["message"] as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "user":
                    if let text = claudeText(message["content"]), promptTitle(text) != nil { entries.append(Entry(kind: .user, text: text)) }
                case "assistant":
                    for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
                        if let text = block["text"] as? String, !text.isEmpty { entries.append(Entry(kind: .assistant, text: text)) }
                    }
                default: break
                }
            } else {
                guard obj["type"] as? String == "response_item", let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message" else { continue }
                let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                switch payload["role"] as? String {
                case "user": entries += texts.filter { promptTitle($0) != nil }.map { Entry(kind: .user, text: $0) }
                case "assistant": entries += texts.filter { !$0.isEmpty }.map { Entry(kind: .assistant, text: $0) }
                default: break
                }
            }
        }
        guard entries.count > limit else { return entries }
        return [Entry(kind: .info, text: "\(entries.count - limit) earlier messages not shown")] + entries.suffix(limit)
    }

    // MARK: - Helpers

    private static func newest(_ files: [URL]) -> [(URL, Date)] {
        files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map { $0 }
    }

    /// The first and last lines of a transcript, without reading a file that may be tens of MB.
    private static func edges(of file: URL) -> (head: [[String: Any]], tail: [[String: Any]]) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], []) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > UInt64(chunk) else { return (lines(head), []) }
        try? handle.seek(toOffset: max(UInt64(chunk), size - UInt64(chunk)))
        let tail = (try? handle.readToEnd()) ?? Data()
        // A line cut in half by the chunk edge isn't valid JSON, so `lines` drops it.
        return (lines(head), lines(tail))
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The first line of something the user typed, or nil for injected context like `<command-name>` or
    /// `<environment_context>`.
    private static func promptTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed.split(separator: "\n", maxSplits: 1).first.map { String($0.prefix(200)) }
    }
}
