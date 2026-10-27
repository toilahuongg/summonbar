import Foundation

enum RunStatus: String, Codable {
    case running, done, failed, stopped
}

struct Entry: Identifiable, Codable {
    enum Kind: String, Codable { case user, assistant, tool, output, error, info }

    var id = UUID()
    var kind: Kind
    var text: String
    var detail: String? = nil
    var isError = false
}

/// One conversation with an agent, run headlessly inside the launcher.
/// Follow-ups resume the agent's own session id, so the conversation can also
/// be continued interactively in a terminal at any point.
@MainActor
final class AgentRun: ObservableObject, Identifiable {
    let id: UUID
    let agentId: String
    let agentName: String
    let projectURL: URL
    let projectName: String
    let createdAt: Date
    private(set) var agent: Agent?

    @Published var title: String
    @Published private(set) var entries: [Entry]
    @Published private(set) var live = ""
    @Published private(set) var status: RunStatus
    @Published private(set) var sessionId: String?
    /// Permission rules for what Claude Code just wasn't allowed to do; Allow & Retry grants them.
    @Published private(set) var deniedRules: [String] = []
    /// Rules granted so far, passed on every later send.
    private(set) var allowedTools: [String] = []

    var onChange: (() -> Void)?

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var stdoutClosed = false
    private var exited = false
    private var stopRequested = false
    private var sawResultError = false
    private var startedItems = Set<String>()
    private var piCost = 0.0
    private var started = Date()

    init(agent: Agent, project: Project) {
        id = UUID()
        agentId = agent.id
        agentName = agent.name
        self.agent = agent
        projectURL = project.url
        projectName = project.name
        createdAt = Date()
        title = ""
        entries = []
        status = .done
    }

    init(record: RunRecord, agent: Agent?) {
        id = record.id
        agentId = record.agentId
        agentName = record.agentName
        self.agent = agent
        projectURL = URL(fileURLWithPath: record.projectPath, isDirectory: true)
        projectName = record.projectName
        createdAt = record.createdAt
        title = record.title
        entries = record.entries
        sessionId = record.sessionId
        allowedTools = record.allowedTools ?? []
        status = record.status == .running ? .stopped : record.status
    }

    /// Picks up a session the agent saved itself, e.g. one started in a terminal.
    init(session: AgentSession, agent: Agent, project: Project, entries: [Entry]) {
        id = UUID()
        agentId = agent.id
        agentName = agent.name
        self.agent = agent
        projectURL = project.url
        projectName = project.name
        createdAt = session.updated
        title = session.title
        self.entries = entries
        sessionId = session.sessionId
        status = .done
    }

    var record: RunRecord {
        RunRecord(id: id, agentId: agentId, agentName: agentName, projectPath: projectURL.path,
                  projectName: projectName, title: title, createdAt: createdAt, sessionId: sessionId,
                  status: status, entries: entries, allowedTools: allowedTools.isEmpty ? nil : allowedTools)
    }

    var isRunning: Bool { status == .running }

    /// Whether a follow-up can continue this conversation.
    var canFollowUp: Bool { agent != nil && !isRunning && (entries.isEmpty || (agent!.canResume && sessionId != nil)) }

    // MARK: - Process lifecycle

    /// `display` is shown in place of `prompt`, for prompts with hidden expansions.
    func send(_ prompt: String, display: String? = nil) {
        guard let agent, !isRunning else { return }
        if title.isEmpty { title = display ?? prompt }
        append(Entry(kind: .user, text: display ?? prompt))
        deniedRules = []

        let resume = agent.canResume ? sessionId : nil
        let (args, stdin) = agent.headlessInvocation(prompt: prompt, resume: resume, allowed: allowedTools)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agent.binary)
        process.arguments = args
        process.currentDirectoryURL = projectURL
        process.environment = Shell.env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        stdoutBuffer = Data()
        stderrTail = ""
        stdoutClosed = false
        exited = false
        stopRequested = false
        sawResultError = false
        startedItems = []
        piCost = 0
        started = Date()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receiveStdout(data) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receiveStderr(text) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.processExited() } }
        }

        do {
            try process.run()
        } catch {
            append(Entry(kind: .error, text: "Could not start \(agent.name): \(error.localizedDescription)"))
            status = .failed
            onChange?()
            return
        }
        self.process = process
        status = .running
        onChange?()

        if let stdin {
            let handle = input.fileHandleForWriting
            DispatchQueue.global().async {
                handle.write(Data(stdin.utf8))
                try? handle.close()
            }
        }
    }

    /// Grants what was denied for the rest of this run and asks the agent to try again.
    func allowAndRetry() {
        let rules = deniedRules
        guard !rules.isEmpty, canFollowUp else { return }
        allowedTools += rules.filter { !allowedTools.contains($0) }
        send("I've allowed \(rules.joined(separator: ", ")). Retry what was denied, then carry on.",
             display: "Allowed \(rules.joined(separator: ", "))")
    }

    func stop() {
        guard let process, isRunning else { return }
        stopRequested = true
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func receiveStdout(_ data: Data) {
        if data.isEmpty {
            if !stdoutBuffer.isEmpty { handleLine(stdoutBuffer); stdoutBuffer = Data() }
            stdoutClosed = true
            finishIfDone()
            return
        }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            handleLine(Data(line))
        }
    }

    private func receiveStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2000))
    }

    private func processExited() {
        exited = true
        finishIfDone()
    }

    private func finishIfDone() {
        guard exited, stdoutClosed, isRunning, let process else { return }
        flushLive()
        let code = process.terminationStatus
        if stopRequested {
            status = .stopped
            append(Entry(kind: .info, text: "Stopped"))
        } else if code == 0 && !sawResultError {
            status = .done
            if agent?.format == .plain { append(Entry(kind: .info, text: "Done · \(elapsed)")) }
        } else {
            status = .failed
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty || !sawResultError {
                append(Entry(kind: .error, text: tail.isEmpty ? "\(agentName) exited with code \(code)" : String(tail.suffix(800))))
            }
        }
        self.process = nil
        onChange?()
    }

    private var elapsed: String {
        String(format: "%.1fs", Date().timeIntervalSince(started))
    }

    // MARK: - Output parsing

    private func handleLine(_ data: Data) {
        guard let agent else { return }
        switch agent.format {
        case .plain:
            let text = String(decoding: data, as: UTF8.self)
            live += (live.isEmpty ? "" : "\n") + text
        case .claude, .codex, .pi:
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { append(Entry(kind: .info, text: text)) }
                return
            }
            switch agent.format {
            case .claude: handleClaude(obj)
            case .codex: handleCodex(obj)
            default: handlePi(obj)
            }
        }
    }

    private func handleClaude(_ obj: [String: Any]) {
        let type = obj["type"] as? String
        if let sid = obj["session_id"] as? String, sessionId != sid, type == "system" || type == "result" {
            sessionId = sid
        }
        // Skip subagent chatter; show only the main thread.
        if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return }

        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            live += text
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    live = ""
                    if let text = block["text"] as? String, !text.isEmpty { append(Entry(kind: .assistant, text: text)) }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    append(Entry(kind: .tool, text: name, detail: summarizeTool(name, input)))
                default:
                    break
                }
            }
        case "user":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                let isError = block["is_error"] as? Bool ?? false
                var text = ""
                if let s = block["content"] as? String {
                    text = s
                } else if let parts = block["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { append(Entry(kind: .output, text: clip(text), isError: isError)) }
            }
        case "result":
            flushLive()
            let denials = obj["permission_denials"] as? [[String: Any]] ?? []
            let rules = denials.flatMap { Self.allowRules(tool: $0["tool_name"] as? String ?? "",
                                                          input: $0["tool_input"] as? [String: Any] ?? [:]) }
            deniedRules = rules.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            if !deniedRules.isEmpty {
                append(Entry(kind: .error, text: "Not allowed without asking: \(deniedRules.joined(separator: ", "))"))
            }
            let isError = obj["is_error"] as? Bool ?? false
            if isError {
                sawResultError = true
                let message = obj["result"] as? String ?? (obj["subtype"] as? String ?? "error")
                append(Entry(kind: .error, text: message))
            }
            var parts = [isError ? "Failed" : "Done"]
            if let ms = obj["duration_ms"] as? Double { parts.append(String(format: "%.1fs", ms / 1000)) }
            if let turns = obj["num_turns"] as? Int { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
            if let cost = obj["total_cost_usd"] as? Double { parts.append(String(format: "$%.3f", cost)) }
            append(Entry(kind: .info, text: parts.joined(separator: " · ")))
        default:
            break
        }
    }

    /// Commands whose second word picks the action, so `git status` doesn't also allow `git push`.
    private static let twoWordCommands: Set<String> = ["git", "gh", "npm", "pnpm", "yarn", "bun", "npx", "cargo",
                                                       "swift", "go", "docker", "kubectl", "brew", "uv", "pip", "pip3"]
    /// Read-only commands Claude Code already runs without asking.
    private static let readOnlyCommands: Set<String> = ["cd", "ls", "cat", "head", "tail", "grep", "wc", "echo", "pwd"]

    /// Claude Code permission rules that would have let a denied tool call through.
    /// Bash gets a prefix rule per command in the line, like the "don't ask again" choice.
    static func allowRules(tool: String, input: [String: Any]) -> [String] {
        func absolute(_ path: String) -> String { "/" + path }  // `//path` is an absolute path in a rule
        switch tool {
        case "Bash":
            let command = input["command"] as? String ?? ""
            let separators = CharacterSet(charactersIn: "&|;\n")
            return command.components(separatedBy: separators).compactMap { part in
                let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
                    .drop { $0.contains("=") || $0 == "(" }
                guard var name = words.first?.trimmingCharacters(in: CharacterSet(charactersIn: "()")),
                      !name.isEmpty, !readOnlyCommands.contains(name) else { return nil }
                if twoWordCommands.contains(name), let action = words.dropFirst().first, !action.hasPrefix("-") {
                    name += " " + action
                }
                return "Bash(\(name):*)"
            }
        case "Read", "Glob", "Grep":
            guard let path = input["file_path"] as? String ?? input["path"] as? String, path.hasPrefix("/") else { return [tool] }
            return ["Read(\(absolute(path))\(tool == "Read" ? "" : "/**"))"]
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            guard let path = input["file_path"] as? String ?? input["notebook_path"] as? String, path.hasPrefix("/") else { return [tool] }
            return ["Edit(\(absolute(path)))"]
        case "WebFetch":
            guard let host = (input["url"] as? String).flatMap(URL.init(string:))?.host else { return [tool] }
            return ["WebFetch(domain:\(host))"]
        default:
            return tool.isEmpty ? [] : [tool]
        }
    }

    private func summarizeTool(_ name: String, _ input: [String: Any]) -> String {
        func str(_ key: String) -> String? { input[key] as? String }
        if let path = str("file_path") ?? str("notebook_path") { return relative(path) }
        if let command = str("command") { return command }
        if let pattern = str("pattern") { return pattern + (str("path").map { "  in " + relative($0) } ?? "") }
        if let path = str("path") { return relative(path) }
        if let url = str("url") { return url }
        if let query = str("query") { return query }
        if let description = str("description") { return description }
        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            let active = todos.first { $0["status"] as? String == "in_progress" }?["content"] as? String
            return active ?? "\(todos.count) todos"
        }
        let json = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return String(json.prefix(120))
    }

    private func handleCodex(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "thread.started":
            if let tid = obj["thread_id"] as? String { sessionId = tid }
        case "item.started":
            guard let item = obj["item"] as? [String: Any], item["type"] as? String == "command_execution" else { return }
            if let id = item["id"] as? String { startedItems.insert(id) }
            append(Entry(kind: .tool, text: "Shell", detail: cleanCodexCommand(item["command"] as? String ?? "")))
        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            let itemId = item["id"] as? String ?? ""
            switch item["type"] as? String {
            case "agent_message":
                if let text = item["text"] as? String, !text.isEmpty { append(Entry(kind: .assistant, text: text)) }
            case "command_execution":
                if !startedItems.contains(itemId) {
                    append(Entry(kind: .tool, text: "Shell", detail: cleanCodexCommand(item["command"] as? String ?? "")))
                }
                let output = (item["aggregated_output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = item["exit_code"] as? Int ?? 0
                if !output.isEmpty || exit != 0 {
                    append(Entry(kind: .output, text: output.isEmpty ? "exit \(exit)" : clip(output), isError: exit != 0))
                }
            case "file_change":
                let changes = item["changes"] as? [[String: Any]] ?? []
                let paths = changes.compactMap { $0["path"] as? String }.map(relative)
                append(Entry(kind: .tool, text: "Edit", detail: paths.joined(separator: ", ")))
            case "mcp_tool_call":
                let server = item["server"] as? String ?? "mcp"
                let tool = item["tool"] as? String ?? "tool"
                append(Entry(kind: .tool, text: "MCP", detail: "\(server).\(tool)"))
            case "web_search":
                append(Entry(kind: .tool, text: "WebSearch", detail: item["query"] as? String ?? ""))
            case "error":
                append(Entry(kind: .error, text: item["message"] as? String ?? "Error"))
            default:
                break
            }
        case "turn.completed":
            var parts = ["Done", elapsed]
            if let usage = obj["usage"] as? [String: Any] {
                let tokens = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
                parts.append("\(tokens.formatted()) tokens")
            }
            append(Entry(kind: .info, text: parts.joined(separator: " · ")))
        case "turn.failed":
            sawResultError = true
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "Turn failed"
            append(Entry(kind: .error, text: message))
        case "error":
            append(Entry(kind: .error, text: obj["message"] as? String ?? "Error"))
        default:
            break
        }
    }

    /// pi's `--mode json` events, which omp emits too.
    private func handlePi(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "session":
            if let sid = obj["id"] as? String { sessionId = sid }
        case "message_update":
            guard let event = obj["assistantMessageEvent"] as? [String: Any],
                  event["type"] as? String == "text_delta",
                  let delta = event["delta"] as? String else { return }
            live += delta
        case "message_end":
            guard let message = obj["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            live = ""
            let content = message["content"] as? [[String: Any]] ?? []
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { append(Entry(kind: .assistant, text: text)) }
            if let cost = ((message["usage"] as? [String: Any])?["cost"] as? [String: Any])?["total"] as? Double { piCost += cost }
            if message["stopReason"] as? String == "error" {
                sawResultError = true
                append(Entry(kind: .error, text: message["errorMessage"] as? String ?? "Error"))
            }
        case "tool_execution_start":
            let name = obj["toolName"] as? String ?? "Tool"
            append(Entry(kind: .tool, text: name.prefix(1).uppercased() + name.dropFirst(),
                         detail: summarizeTool(name, obj["args"] as? [String: Any] ?? [:])))
        case "tool_execution_end":
            let isError = obj["isError"] as? Bool ?? false
            let content = (obj["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { append(Entry(kind: .output, text: clip(text), isError: isError)) }
        case "auto_retry_end":
            if obj["success"] as? Bool == false {
                sawResultError = true
                append(Entry(kind: .error, text: obj["finalError"] as? String ?? "Retries failed"))
            }
        case "agent_end":
            flushLive()
            var parts = [sawResultError ? "Failed" : "Done", elapsed]
            if piCost > 0 { parts.append(String(format: "$%.3f", piCost)) }
            append(Entry(kind: .info, text: parts.joined(separator: " · ")))
        default:
            break
        }
    }

    /// `/bin/zsh -lc 'npm test'` → `npm test`
    private func cleanCodexCommand(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var inner = String(command.dropFirst(prefix.count))
            if inner.hasPrefix("'") && inner.hasSuffix("'") && inner.count >= 2 {
                inner = String(inner.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            }
            return inner
        }
        return command
    }

    // MARK: - Helpers

    private func append(_ entry: Entry) {
        entries.append(entry)
        onChange?()
    }

    private func flushLive() {
        let text = live.trimmingCharacters(in: .whitespacesAndNewlines)
        live = ""
        if !text.isEmpty { append(Entry(kind: .assistant, text: text)) }
    }

    private func relative(_ path: String) -> String {
        let root = projectURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func clip(_ text: String, limit: Int = 1500) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
