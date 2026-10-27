import Foundation

/// GUI apps start with launchd's bare environment, so agents installed via nvm,
/// ~/.local/bin, Homebrew etc. are invisible. We capture the user's login +
/// interactive shell environment once and use it for every spawned process.
enum Shell {
    static private(set) var env: [String: String] = ProcessInfo.processInfo.environment

    static func loadUserEnvironment() {
        var result = ProcessInfo.processInfo.environment
        if let captured = captureLoginEnvironment() {
            result.merge(captured) { _, shell in shell }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (result["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in fallbacks where !path.contains(dir) { path.append(dir) }
        result["PATH"] = path.joined(separator: ":")
        // Don't let agents think they are nested inside another Claude Code session.
        result.removeValue(forKey: "CLAUDECODE")
        result.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env = result
    }

    private static func captureLoginEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__SUMMONBAR_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)'; env -0; printf '\(marker)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        do { try process.run() } catch { return nil }

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var env: [String: String] = [:]
        for pair in parts[1].split(separator: "\0") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    static func which(_ name: String) -> String? {
        let fm = FileManager.default
        if name.contains("/") {
            let path = Config.expand(name)
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fire-and-forget helper for short commands (open, git init …).
    @discardableResult
    static func run(_ executable: String, _ args: [String], in dir: URL? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        if let dir { process.currentDirectoryURL = dir }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
