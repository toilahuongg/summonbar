import Foundation
import ServiceManagement

/// Launch at login through SMAppService. macOS keys the login item to the code
/// signature: a build signed with a certificate (Developer ID or Apple
/// Development) keeps it across updates, but an ad-hoc build (a local build
/// without a certificate, or an older release) is tied to its cdhash, so after a rebuild `status` reads "not registered" while
/// System Settings still shows it on. The user's choice is kept here and
/// registered again on launch.
enum LoginItem {
    private static let key = "launchAtLogin"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        UserDefaults.standard.set(on, forKey: key)
        if on {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Re-registers this build if the user turned launch at login on. Leaves
    /// it alone when it was switched off in System Settings (requiresApproval).
    static func restore() {
        let status = SMAppService.mainApp.status
        guard UserDefaults.standard.bool(forKey: key), status != .enabled, status != .requiresApproval else { return }
        try? SMAppService.mainApp.register()
    }
}
