import Foundation

/// A script that builds a prompt for a coding agent. It runs inside a project,
/// and whatever it prints is sent to the agent as the task.
struct ExtensionArgument {
    enum Kind { case text, dropdown }

    var kind: Kind
    var placeholder: String
    var optional: Bool
    /// (title, value) pairs for dropdowns.
    var options: [(title: String, value: String)]
}

struct Extension: Identifiable {
    let url: URL
    let title: String
    let description: String?
    let icon: String
    let arguments: [ExtensionArgument]
    let needsConfirmation: Bool
    /// Agent id to send the prompt to; nil means the default agent.
    let agentId: String?
    /// Interpreter + script, so files without the executable bit still run.
    let command: [String]

    var id: String { url.path }
}

enum ExtensionCatalog {
    static let directory = Config.directory.appendingPathComponent("extensions", isDirectory: true)

    private static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "icns", "pdf", "md", "txt", "json", "yml", "yaml", "lock", "zip",
    ]

    static func scan(config: Config) -> [Extension] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) { writeExamples() }
        var seen = Set<String>()
        var found: [Extension] = []
        for dir in [directory] + config.extensionDirectories {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level > 3 { walker.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !skippedExtensions.contains(url.pathExtension.lowercased()),
                      seen.insert(url.resolvingSymlinksInPath().path).inserted,
                      let ext = parse(url) else { continue }
                found.append(ext)
            }
        }
        return found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reads `@summonbar.key value` comments from the file header.
    static func parse(_ url: URL) -> Extension? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        var meta: [String: String] = [:]
        for line in lines.prefix(80) {
            guard let range = line.range(of: "@summonbar.") else { continue }
            let rest = line[range.upperBound...]
            let key = String(rest.prefix { $0.isLetter || $0.isNumber })
            if !key.isEmpty { meta[key] = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
        }
        guard let title = meta["title"], !title.isEmpty, let command = command(for: url, firstLine: lines.first) else { return nil }
        // Scripts written for the old output modes (silent, fullOutput, …) aren't prompts; skip them.
        if let mode = meta["mode"], !mode.isEmpty, mode != "agent" { return nil }

        return Extension(
            url: url, title: title,
            description: meta["description"].flatMap { $0.isEmpty ? nil : $0 },
            icon: resolveIcon(meta["icon"], dir: url.deletingLastPathComponent()),
            arguments: (1...3).compactMap { meta["argument\($0)"].flatMap(parseArgument) },
            needsConfirmation: meta["needsConfirmation"]?.lowercased() == "true",
            agentId: meta["agent"].flatMap { $0.isEmpty ? nil : $0 },
            command: command)
    }

    private static func command(for url: URL, firstLine: String?) -> [String]? {
        if FileManager.default.isExecutableFile(atPath: url.path) { return [url.path] }
        guard let line = firstLine, line.hasPrefix("#!") else { return nil }
        let parts = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = parts.first else { return nil }
        return [interpreter] + parts.dropFirst() + [url.path]
    }

    private static func parseArgument(_ json: String) -> ExtensionArgument? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let options = (obj["data"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
            guard let value = item["value"] as? String else { return nil }
            return ((item["title"] as? String) ?? value, value)
        }
        let isDropdown = (obj["type"] as? String)?.lowercased() == "dropdown" && !options.isEmpty
        return ExtensionArgument(kind: isDropdown ? .dropdown : .text,
                                 placeholder: obj["placeholder"] as? String ?? "Value",
                                 optional: obj["optional"] as? Bool ?? false,
                                 options: options)
    }

    /// SF Symbol name, emoji, or an image path relative to the script.
    private static func resolveIcon(_ raw: String?, dir: URL) -> String {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("http") else { return "puzzlepiece.extension" }
        let imageTypes = ["png", "jpg", "jpeg", "icns", "gif", "tiff"]
        guard imageTypes.contains((raw as NSString).pathExtension.lowercased()) else { return raw }
        let expanded = Config.expand(raw)
        return expanded.hasPrefix("/") ? expanded : dir.appendingPathComponent(expanded).path
    }

    private static func writeExamples() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let examples = [
            ("review-diff.sh", """
            #!/bin/bash
            # @summonbar.title Review Uncommitted Changes
            # @summonbar.description Ask the agent to review git diff
            # @summonbar.icon checkmark.seal
            # @summonbar.argument1 { "type": "text", "placeholder": "Focus (optional)", "optional": true }

            echo "Review my uncommitted changes for bugs and risky edits. ${1:+Focus on: $1}"
            echo
            echo '```diff'
            git diff HEAD | head -c 60000
            echo '```'
            """),
            ("commit-message.sh", """
            #!/bin/bash
            # @summonbar.title Write Commit Message
            # @summonbar.description Draft a commit message for the staged changes
            # @summonbar.icon text.badge.checkmark

            echo "Write a concise commit message for these staged changes. Don't commit, just print it."
            echo
            echo '```diff'
            git diff --cached | head -c 60000
            echo '```'
            """),
            ("fix-tests.sh", """
            #!/bin/bash
            # @summonbar.title Fix Failing Tests
            # @summonbar.description Run the tests and hand the failures to the agent
            # @summonbar.icon wrench.and.screwdriver
            # @summonbar.argument1 { "type": "text", "placeholder": "Test command", "optional": true }

            cmd="${1:-npm test}"
            echo "Running \\`$cmd\\` fails. Find the cause and fix it, then run it again to confirm."
            echo
            echo '```'
            eval "$cmd" 2>&1 | tail -c 30000
            echo '```'
            """),
        ]
        for (name, body) in examples {
            let url = directory.appendingPathComponent(name)
            try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

/// One execution of an extension script, with its output (the prompt) captured.
@MainActor
final class ExtensionRun: ObservableObject {
    let ext: Extension
    let project: Project
    let arguments: [String]
    let environment: [String: String]

    @Published private(set) var output = ""
    @Published private(set) var status: RunStatus = .done

    var onFinish: ((ExtensionRun) -> Void)?

    private var process: Process?
    private var stopRequested = false
    private var openPipes = 0
    private var exited = false
    private static let maxOutput = 200_000

    init(ext: Extension, project: Project, arguments: [String], environment: [String: String]) {
        self.ext = ext
        self.project = project
        self.arguments = arguments
        self.environment = environment
    }

    var isRunning: Bool { status == .running }

    /// The prompt to send, once the script has finished cleanly.
    var prompt: String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == .done && !text.isEmpty ? text : nil
    }

    func start() {
        guard !isRunning else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ext.command[0])
        process.arguments = Array(ext.command.dropFirst()) + arguments
        process.currentDirectoryURL = project.url
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        output = ""
        stopRequested = false
        exited = false
        openPipes = 2
        for pipe in [out, err] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.receive(data) } }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.exited = true; self?.finishIfDone() } }
        }
        do {
            try process.run()
        } catch {
            output = "Could not run \(ext.url.lastPathComponent): \(error.localizedDescription)"
            status = .failed
            onFinish?(self)
            return
        }
        self.process = process
        status = .running
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

    private func receive(_ data: Data) {
        guard !data.isEmpty else { openPipes -= 1; finishIfDone(); return }
        output += Self.stripANSI(String(decoding: data, as: UTF8.self))
        if output.count > Self.maxOutput { output = String(output.suffix(Self.maxOutput)) }
    }

    private func finishIfDone() {
        guard exited, openPipes <= 0, isRunning, let process else { return }
        let code = process.terminationStatus
        status = stopRequested ? .stopped : (code == 0 ? .done : .failed)
        if status == .failed && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = "\(ext.title) exited with code \(code)"
        }
        self.process = nil
        onFinish?(self)
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}")

    private static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
