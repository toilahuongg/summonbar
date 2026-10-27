import AppKit
import CryptoKit

/// Updates Summonbar in place from GitHub Releases: downloads the release zip,
/// checks it, swaps it in for the running app and relaunches.
@MainActor
final class Updater: ObservableObject {
    struct Release {
        let version: String
        let name: String
        let notes: String
        let page: URL
        let download: URL
        /// SHA-256 from GitHub's asset digest, when it has one.
        let sha256: String?
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    static let shared = Updater()
    nonisolated static let repository = "toilahuongg/summonbar"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    @Published private(set) var state = State.idle { didSet { onChange() } }
    @Published private(set) var lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    var onChange: () -> Void = {}
    /// Asked before relaunching; returns false to keep the running app.
    var confirmRelaunch: () -> Bool = { true }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    /// Checks shortly after launch and then once a day while `enabled()` says so.
    func startAutomaticChecks(enabled: @escaping () -> Bool) {
        timer?.invalidate()
        let tick = { [weak self] in
            guard let self, enabled(), !isBusy, available == nil else { return }
            if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
            Task { await self.check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    /// Looks up the latest release. Returns it when it's newer than this build.
    @discardableResult
    func check() async -> Release? {
        guard !isBusy else { return available }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
            if Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                return release
            }
            state = .upToDate
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
        return nil
    }

    /// Downloads and installs `release`, then relaunches. Only returns on failure or when the relaunch is declined.
    func install(_ release: Release) async {
        guard !isBusy else { return }
        guard confirmRelaunch() else { return }
        state = .installing(release)
        do {
            let app = try await Self.download(release)
            let bundle = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
            relaunch(bundle)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func relaunch(_ bundle: URL) {
        // A detached shell waits for this process to exit, then opens the new build.
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(Shell.quote(bundle.path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    nonisolated private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try expectOK(response)
        let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = latest.assets.first(where: { $0.name.hasPrefix("Summonbar") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("the latest release has no Summonbar zip")
        }
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        return Release(version: version, name: latest.name ?? "Summonbar \(version)", notes: latest.body ?? "",
                       page: latest.html_url, download: asset.browser_download_url,
                       sha256: asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
    }

    /// Downloads and unpacks the release next to the running app (same volume, so the swap is a rename)
    /// and returns the checked Summonbar.app.
    nonisolated private static func download(_ release: Release) async throws -> URL {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: Bundle.main.bundleURL, create: true)
        let (temp, response) = try await URLSession.shared.download(from: release.download)
        try expectOK(response)
        let zip = staging.appendingPathComponent("Summonbar.zip")
        try fm.moveItem(at: temp, to: zip)

        if let expected = release.sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("the download doesn't match its SHA-256") }
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], "Couldn't unzip the update")
        let app = unpacked.appendingPathComponent("Summonbar.app", isDirectory: true)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("the zip doesn't contain Summonbar.app")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == release.version else {
            throw UpdateError("the zip holds version \(version ?? "?"), not \(release.version)")
        }
        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], "The update's signature is broken")
        // Gatekeeper would block an ad-hoc signed app that's still quarantined.
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], "")
        return app
    }

    nonisolated private static func expectOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("GitHub answered \(http.statusCode)")
        }
    }

    nonisolated private static func runTool(_ path: String, _ args: [String], _ failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw UpdateError(failure) }
    }

    /// Compares dotted versions numerically: 0.10.0 is newer than 0.9.1.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
