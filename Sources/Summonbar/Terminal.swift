import AppKit

/// Opens a terminal window in a directory, optionally running a command.
/// We write a small `.command` script so the same mechanism works across
/// Terminal, iTerm, Ghostty and friends, and so PATH matches the user's shell.
enum TerminalLauncher {
    static var scriptsDir: URL { Store.directory.appendingPathComponent("launch", isDirectory: true) }

    static func open(command: [String]?, in dir: URL, terminal: String) {
        let script = makeScript(command: command, dir: dir)
        switch terminal.lowercased() {
        case "ghostty":
            Shell.run("/usr/bin/open", ["-na", "Ghostty.app", "--args", "--working-directory=\(dir.path)", "-e", "/bin/zsh", script.path])
        case "iterm", "iterm2":
            Shell.run("/usr/bin/open", ["-a", "iTerm", script.path])
        case "terminal":
            Shell.run("/usr/bin/open", ["-a", "Terminal", script.path])
        default:
            Shell.run("/usr/bin/open", ["-a", terminal, script.path])
        }
    }

    private static func makeScript(command: [String]?, dir: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let url = scriptsDir.appendingPathComponent("\(UUID().uuidString.prefix(8)).command")
        var lines = [
            "#!/bin/zsh",
            "export PATH=\(Shell.quote(Shell.env["PATH"] ?? "/usr/bin:/bin"))",
            "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT",
            "cd \(Shell.quote(dir.path)) || exit 1",
            "rm -f \(Shell.quote(url.path))",
        ]
        if let command {
            lines += ["clear", command.map(Shell.quote).joined(separator: " ")]
        }
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Scripts delete themselves when run; sweep any that never ran.
    static func cleanUp() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        for file in (try? fm.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    static func openInEditor(_ dir: URL, editor: String) {
        Shell.run("/usr/bin/open", ["-a", editor, dir.path])
    }
}
