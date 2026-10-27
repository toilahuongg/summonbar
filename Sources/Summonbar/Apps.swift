import AppKit

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    /// Localized name as Finder shows it, e.g. "System Settings".
    let name: String
    /// The bundle's file name without `.app`; also searched, so English names work on a localized system.
    let fileName: String
    let bundleId: String?
    let version: String?

    var id: String { url.path }
    /// Key for aliases, hotkeys and hidden apps in config.json; survives the app moving.
    var key: String { bundleId ?? url.path }
    var isSystem: Bool { url.path.hasPrefix("/System/") }
}

enum AppScanner {
    static let defaultDirectories: [URL] = [
        "/Applications", "/System/Applications", "~/Applications",
        "/System/Library/CoreServices/Applications",
    ].map { URL(fileURLWithPath: Config.expand($0), isDirectory: true) }

    /// Apps outside the usual folders that people still expect to find.
    private static let extras = ["/System/Library/CoreServices/Finder.app"]

    /// Scans app folders two levels deep (e.g. /Applications/Utilities, Setapp, Adobe folders).
    /// Apps with the same bundle id are listed once, in folder order.
    static func scan(extraDirectories: [URL] = []) -> [InstalledApp] {
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func add(_ url: URL) {
            let app = make(url)
            guard seen.insert(app.key).inserted else { return }
            out.append(app)
        }
        for dir in defaultDirectories + extraDirectories {
            collect(in: dir, depth: 2).forEach(add)
        }
        extras.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .forEach(add)
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func make(_ url: URL) -> InstalledApp {
        let info = Bundle(url: url)?.infoDictionary
        let fileName = url.deletingPathExtension().lastPathComponent
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return InstalledApp(url: url, name: name, fileName: fileName,
                            bundleId: info?["CFBundleIdentifier"] as? String,
                            version: info?["CFBundleShortVersionString"] as? String)
    }

    private static func collect(in dir: URL, depth: Int) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [URL] = []
        for item in items {
            if item.pathExtension == "app" {
                out.append(item)
            } else if depth > 1, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out += collect(in: item, depth: depth - 1)
            }
        }
        return out
    }
}

/// Opening, quitting and trashing apps.
@MainActor
enum AppControl {
    /// Running apps keyed by bundle path.
    static func running() -> [String: NSRunningApplication] {
        var out: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let path = app.bundleURL?.path { out[path] = app }
        }
        return out
    }

    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Quits politely (the app may ask to save), waits for it to exit, then opens it again.
    static func restart(_ running: NSRunningApplication, at url: URL) async -> Bool {
        guard running.terminate() else { return false }
        for _ in 0..<50 where !running.isTerminated {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard running.isTerminated else { return false }
        open(url)
        return true
    }

    /// Apps with a Dock icon, except Finder and Summonbar itself.
    static func quittable() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func canTrash(_ app: InstalledApp) -> Bool {
        !app.isSystem && FileManager.default.isDeletableFile(atPath: app.url.path)
    }

    private static var icons: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}
