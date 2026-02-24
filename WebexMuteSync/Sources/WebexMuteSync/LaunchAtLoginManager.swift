import ServiceManagement

/// Manages "Launch at Login" using SMAppService (macOS 13+).
/// Only works when running from an .app bundle.
enum LaunchAtLoginManager {
    /// Whether the app is running from an .app bundle (required for SMAppService)
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Whether launch at login is currently enabled
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Toggle launch at login on/off
    static func toggle() {
        guard isAvailable else { return }
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[LaunchAtLogin] Failed to toggle: \(error)")
        }
    }
}
