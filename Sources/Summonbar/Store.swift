import Foundation

struct RunRecord: Codable {
    var id: UUID
    var agentId: String
    var agentName: String
    var projectPath: String
    var projectName: String
    var title: String
    var createdAt: Date
    var sessionId: String?
    var status: RunStatus
    var entries: [Entry]
    /// Claude Code permission rules granted with Allow & Retry.
    var allowedTools: [String]?
}

/// Persists agent runs and project usage under ~/Library/Application Support/Summonbar.
enum Store {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Summonbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let runsURL = directory.appendingPathComponent("runs.json")
    private static let usageURL = directory.appendingPathComponent("usage.json")
    private static let appUsageURL = directory.appendingPathComponent("app-usage.json")
    private static let clipboardURL = directory.appendingPathComponent("clipboard.json")
    private static let recentsURL = directory.appendingPathComponent("recents.json")
    static let maxRuns = 100
    static let maxRecents = 20

    static func loadRuns() -> [RunRecord] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        return (try? decoder.decode([RunRecord].self, from: data)) ?? []
    }

    static func saveRuns(_ runs: [RunRecord]) {
        guard let data = try? encoder.encode(Array(runs.prefix(maxRuns))) else { return }
        try? data.write(to: runsURL, options: .atomic)
    }

    /// Last-used dates for projects, or for apps opened from the launcher.
    static func loadUsage(apps: Bool = false) -> [String: Date] {
        guard let data = try? Data(contentsOf: apps ? appUsageURL : usageURL) else { return [:] }
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    static func saveUsage(_ usage: [String: Date], apps: Bool = false) {
        guard let data = try? encoder.encode(usage) else { return }
        try? data.write(to: apps ? appUsageURL : usageURL, options: .atomic)
    }

    /// IDs of launcher items picked from the root list, most recent first.
    static func loadRecents() -> [String] {
        guard let data = try? Data(contentsOf: recentsURL) else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    static func saveRecents(_ ids: [String]) {
        guard let data = try? encoder.encode(Array(ids.prefix(maxRecents))) else { return }
        try? data.write(to: recentsURL, options: .atomic)
    }

    static func loadClipboard() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: clipboardURL) else { return [] }
        return (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
    }

    static func saveClipboard(_ entries: [ClipboardEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: clipboardURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
