import Foundation

struct Project: Identifiable, Hashable {
    let url: URL
    /// Path relative to the workspaces root, e.g. `misoapps/home-page`.
    let name: String
    let kind: String?
    let modified: Date

    var id: String { url.path }
}

enum ProjectScanner {
    private static let markers = [
        ".git", "package.json", "Cargo.toml", "Package.swift", "go.mod", "pyproject.toml",
        "requirements.txt", "Gemfile", "composer.json", "pubspec.yaml", "build.gradle", "pom.xml",
        "deno.json", "Makefile", "CLAUDE.md", "AGENTS.md", "shopify.app.toml", "config/settings_schema.json",
    ]

    static func scan(root: URL) -> [Project] {
        var projects: [Project] = []
        for dir in subdirectories(of: root) {
            let children = subdirectories(of: dir)
            if !isProject(dir) && children.contains(where: isProject) {
                // A grouping folder like ~/Workspaces/misoapps: its children are the projects.
                projects += children.map { make($0, root: root) }
            } else {
                projects.append(make(dir, root: root))
            }
        }
        return projects.sorted { $0.modified > $1.modified }
    }

    static func make(_ url: URL, root: URL) -> Project {
        let name = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
        return Project(url: url, name: name, kind: kind(of: url), modified: modified(url))
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true && $0.lastPathComponent != "node_modules"
        }
    }

    private static func isProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        return markers.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static func kind(of url: URL) -> String? {
        let fm = FileManager.default
        func has(_ file: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(file).path) }
        if has("shopify.app.toml") { return "Shopify App" }
        if has("config/settings_schema.json") { return "Shopify Theme" }
        if has("Package.swift") { return "Swift" }
        if has("Cargo.toml") { return has("src-tauri") ? "Tauri" : "Rust" }
        if has("src-tauri") { return "Tauri" }
        if has("go.mod") { return "Go" }
        if has("pyproject.toml") || has("requirements.txt") { return "Python" }
        if has("pubspec.yaml") { return "Flutter" }
        if has("package.json") { return "Node" }
        return nil
    }

    private static func modified(_ url: URL) -> Date {
        let candidates = [url.appendingPathComponent(".git/index"), url]
        let dates = candidates.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return dates.max() ?? .distantPast
    }
}

enum Fuzzy {
    /// Higher is better; nil means no match. Substring matches beat scattered ones.
    static func score(_ query: String, _ target: String) -> Int? {
        let q = query.lowercased(), t = target.lowercased()
        if q.isEmpty { return 0 }
        if let range = t.range(of: q) {
            let start = t.distance(from: t.startIndex, to: range.lowerBound)
            let atWordStart = start == 0 || "/-_ .".contains(t[t.index(before: range.lowerBound)])
            return 1000 - start * 5 + (atWordStart ? 200 : 0) - (t.count - q.count)
        }
        var score = 0, ti = t.startIndex, last: String.Index? = nil
        for ch in q {
            guard let found = t[ti...].firstIndex(of: ch) else { return nil }
            if let last, t.index(after: last) == found { score += 10 } else { score -= t.distance(from: ti, to: found) }
            last = found
            ti = t.index(after: found)
        }
        return score
    }
}
