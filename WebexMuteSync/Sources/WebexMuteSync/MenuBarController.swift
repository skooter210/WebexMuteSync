import AppKit

/// Manages the menu bar status item (icon and dropdown menu).
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var deviceMenuItem: NSMenuItem!
    private var connectionMenuItem: NSMenuItem!

    private(set) var currentStatus: SyncStatus = .webexNotRunning

    /// Timer for ringing animation
    private var ringAnimationTimer: Timer?
    private var ringAnimationFrame: Int = 0
    private let ringAnimationSymbols = [
        "phone.fill",
        "phone.and.waveform.fill",
        "phone.badge.waveform.fill",
        "phone.and.waveform.fill",
    ]

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WebexMuteSync")
            image?.isTemplate = true
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()

        // Device info section
        deviceMenuItem = NSMenuItem(title: "Device: Not connected", action: nil, keyEquivalent: "")
        deviceMenuItem.isEnabled = false
        menu.addItem(deviceMenuItem)

        connectionMenuItem = NSMenuItem(title: "Connection: —", action: nil, keyEquivalent: "")
        connectionMenuItem.isEnabled = false
        menu.addItem(connectionMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Status
        statusMenuItem = NSMenuItem(title: "Status: Initializing...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit WebexMuteSync", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        updateDisplay(status: .webexNotRunning)
    }

    /// Update device info in the menu dropdown.
    func updateDeviceInfo(connected: Bool, isUSB: Bool) {
        if connected {
            deviceMenuItem?.title = "Anker PowerConf S3"
            connectionMenuItem?.title = isUSB ? "Connection: USB" : "Connection: Bluetooth (LED unavailable)"
        } else {
            deviceMenuItem?.title = "Device: Not connected"
            connectionMenuItem?.title = "Connection: —"
        }
    }

    func updateDisplay(status: SyncStatus) {
        let previousStatus = currentStatus
        currentStatus = status

        // Stop ringing animation if we're leaving ringing state
        if previousStatus == .ringing && status != .ringing {
            stopRingAnimation()
        }

        // Start ringing animation if entering ringing state
        if status == .ringing && previousStatus != .ringing {
            startRingAnimation()
            return  // animation handles icon updates
        }

        // If still ringing, let the animation timer handle it
        if status == .ringing {
            return
        }

        guard let button = statusItem?.button else { return }

        let symbolName: String
        let statusText: String

        switch status {
        case .muted:
            symbolName = "mic.slash.fill"
            statusText = "Muted (synced)"
        case .unmuted:
            symbolName = "mic.fill"
            statusText = "Unmuted (synced)"
        case .syncing:
            symbolName = "mic.badge.xmark"
            statusText = "Syncing..."
        case .ringing:
            // Handled above by animation
            return
        case .idle:
            symbolName = "mic.fill"
            statusText = "No active meeting"
        case .deviceDisconnected:
            symbolName = "mic.badge.xmark"
            statusText = "Anker device not connected"
        case .webexNotRunning:
            symbolName = "mic.fill"
            statusText = "Webex not running"
        case .usbRequired:
            symbolName = "mic.badge.xmark"
            statusText = "USB connection required (Bluetooth detected)"
        }

        let tint: NSColor?
        switch status {
        case .muted:
            tint = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        case .unmuted:
            tint = .systemGreen
        case .idle, .webexNotRunning:
            tint = nil  // template mode — adapts to dark/light
        case .syncing, .deviceDisconnected, .usbRequired:
            tint = .systemOrange
        case .ringing:
            tint = nil
        }

        applyIcon(symbolName: symbolName, tint: tint, to: button)

        statusMenuItem?.title = "Status: \(statusText)"
    }

    // MARK: - Ringing Animation

    private func startRingAnimation() {
        ringAnimationFrame = 0
        statusMenuItem?.title = "Status: Incoming call..."

        // Immediately show first frame
        updateRingFrame()

        ringAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.ringAnimationFrame = (self.ringAnimationFrame + 1) % self.ringAnimationSymbols.count
            self.updateRingFrame()
        }
    }

    private func updateRingFrame() {
        guard let button = statusItem?.button else { return }
        let symbolName = ringAnimationSymbols[ringAnimationFrame]
        applyIcon(symbolName: symbolName, tint: .systemGreen, to: button)
    }

    private func stopRingAnimation() {
        ringAnimationTimer?.invalidate()
        ringAnimationTimer = nil
        ringAnimationFrame = 0
    }

    // MARK: - Helpers

    private func applyIcon(symbolName: String, tint: NSColor?, to button: NSStatusBarButton) {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WebexMuteSync") else { return }

        if let tint = tint {
            // Draw a manually tinted non-template image
            let size = NSSize(width: 18, height: 18)
            let tinted = NSImage(size: size, flipped: false) { rect in
                baseImage.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            button.contentTintColor = nil
            button.image = tinted
        } else {
            // Template mode — adapts to dark/light menu bar automatically
            baseImage.size = NSSize(width: 18, height: 18)
            baseImage.isTemplate = true
            button.contentTintColor = nil
            button.image = baseImage
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
