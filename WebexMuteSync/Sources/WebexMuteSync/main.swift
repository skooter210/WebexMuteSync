import AppKit

/// Main application class for WebexMuteSync.
/// Runs as a menu bar-only app (no dock icon) using LSUIElement behavior.
class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private let syncEngine = SyncEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("[App] Accessibility permission not granted — Webex monitoring will not work")
            print("[App] Please enable in System Settings > Privacy & Security > Accessibility")
        }

        menuBarController.setup()

        syncEngine.delegate = self
        syncEngine.start()

        print("[App] WebexMuteSync started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncEngine.stop()
        print("[App] WebexMuteSync stopped")
    }
}

extension AppDelegate: SyncEngineDelegate {
    func syncEngine(_ engine: SyncEngine, didUpdateStatus status: SyncStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateDisplay(status: status)
        }
    }

    func syncEngine(_ engine: SyncEngine, deviceConnected: Bool, isUSB: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateDeviceInfo(connected: deviceConnected, isUSB: isUSB)
        }
    }
}

// MARK: - Entry Point

// Disable stdout buffering so logs appear in real time when redirected to a file
setbuf(stdout, nil)
setbuf(stderr, nil)

// Set LSUIElement behavior (no dock icon) programmatically
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
