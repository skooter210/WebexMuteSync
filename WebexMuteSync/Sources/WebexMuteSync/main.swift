import AppKit

/// Main application class for WebexMuteSync.
/// Runs as a menu bar-only app (no dock icon) using LSUIElement behavior.
class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()
    private let syncEngine = SyncEngine()
    private var testPanel: DeviceTestPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("[App] Accessibility permission not granted — Webex monitoring will not work")
            print("[App] Please enable in System Settings > Privacy & Security > Accessibility")
        }

        menuBarController.setup()

        // Wire menu bar toggle actions to sync engine
        menuBarController.onToggleAudio = { [weak self] in
            self?.syncEngine.toggleWebexMute()
        }
        menuBarController.onToggleVideo = { [weak self] in
            self?.syncEngine.toggleWebexVideo()
        }
        menuBarController.onLeaveCall = { [weak self] in
            self?.syncEngine.leaveWebexMeeting()
        }

        // Wire "Configure Device..." menu item
        menuBarController.onConfigureDevice = { [weak self] in
            self?.openTestPanel()
        }

        syncEngine.delegate = self
        syncEngine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncEngine.stop()
    }

    // MARK: - Test Panel

    private func openTestPanel() {
        // Close existing panel if any
        testPanel?.close()

        guard syncEngine.hidDevice.isConnected else { return }

        let panel = DeviceTestPanel(hidDevice: syncEngine.hidDevice)

        panel.onSaveProfile = { [weak self] profile in
            do {
                try ProfileManager.shared.saveProfile(profile)
                let alert = NSAlert()
                alert.messageText = "Profile Saved"
                alert.informativeText = "Device profile for \(profile.name) has been saved. It will be used automatically next time this device connects."
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
            self?.testPanel?.close()
        }

        panel.onSubmitToGitHub = { profile in
            GitHubSubmitter.submitProfile(profile) { result in
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    switch result {
                    case .success(let url):
                        alert.messageText = "Profile Submitted"
                        alert.informativeText = "GitHub issue created:\n\(url)"
                        alert.alertStyle = .informational
                    case .failure(let error):
                        alert.messageText = "Submission Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                    }
                    alert.runModal()
                }
            }
        }

        panel.onClose = { [weak self] in
            self?.syncEngine.resumeSync()
            self?.testPanel = nil
        }

        syncEngine.pauseSync()
        testPanel = panel

        // Bring to front since we're an accessory app
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: SyncEngineDelegate {
    func syncEngine(_ engine: SyncEngine, didUpdateStatus status: SyncStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateDisplay(status: status)
        }
    }

    func syncEngine(_ engine: SyncEngine, deviceConnected: Bool, isUSB: Bool, productName: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateDeviceInfo(connected: deviceConnected, isUSB: isUSB, productName: productName)
        }
    }

    func syncEngine(_ engine: SyncEngine, didUpdateVideoState state: WebexVideoState) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateVideoState(state)
        }
    }

    func syncEngine(_ engine: SyncEngine, deviceProfileStatus isKnown: Bool, profile: DeviceProfile?) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.updateProfileStatus(isKnown: isKnown, hasDevice: profile != nil)

            // If device disconnected while test panel is open, close it
            if profile == nil {
                self?.testPanel?.close()
            }
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
