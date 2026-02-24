import AppKit

// MARK: - Circular Toggle Button

/// A circular button with an SF Symbol icon, matching the Webex meeting control style.
/// Uses NSView with direct mouse handling instead of NSButton, because NSButton's
/// target-action doesn't fire reliably on repeated clicks inside NSMenu custom views.
private final class CircleToggleButton: NSView {
    private let iconSize: CGFloat = 18
    private let buttonSize: CGFloat = 36

    private var onSymbol: String    // symbol when "on" (e.g. unmuted / video on)
    private var offSymbol: String   // symbol when "off" (e.g. muted / video off)
    private(set) var isOn: Bool = true
    private(set) var isEnabled: Bool = true
    private var isPressed: Bool = false
    private var clickHandler: (() -> Void)?

    init(onSymbol: String, offSymbol: String, action: @escaping () -> Void) {
        self.onSymbol = onSymbol
        self.offSymbol = offSymbol
        self.clickHandler = action
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))

        self.wantsLayer = true

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonSize),
            heightAnchor.constraint(equalToConstant: buttonSize),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func setState(isOn: Bool, enabled: Bool) {
        self.isOn = isOn
        self.isEnabled = enabled
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }

        // Flash pressed state
        isPressed = true
        needsDisplay = true

        // Fire action immediately on mouseDown — mouseUp is unreliable inside NSMenu
        clickHandler?()

        // Reset pressed state after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isPressed = false
            self?.needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // No-op: action fires on mouseDown for NSMenu compatibility
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))

        // Background circle
        if isEnabled {
            if isPressed {
                NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
            } else if isOn {
                NSColor.controlBackgroundColor.withAlphaComponent(0.3).setFill()
            } else {
                NSColor.systemRed.withAlphaComponent(0.2).setFill()
            }
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.1).setFill()
        }
        path.fill()

        // Border
        if isEnabled {
            NSColor.separatorColor.setStroke()
        } else {
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        // Icon
        let symbolName = isOn ? onSymbol : offSymbol
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }

        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        let configured = image.withSymbolConfiguration(config) ?? image

        let tint: NSColor
        if !isEnabled {
            tint = .tertiaryLabelColor
        } else if isOn {
            tint = .labelColor
        } else {
            tint = .systemRed
        }

        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false

        let imageSize = tinted.size
        let x = (bounds.width - imageSize.width) / 2
        let y = (bounds.height - imageSize.height) / 2
        tinted.draw(in: NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height))
    }
}

// MARK: - Toggle Controls View

/// Custom view for the menu item containing circular audio/video toggle buttons.
private final class ToggleControlsView: NSView {
    let audioButton: CircleToggleButton
    let videoButton: CircleToggleButton

    private let audioLabel = NSTextField(labelWithString: "Mute")
    private let videoLabel = NSTextField(labelWithString: "Video")

    init(onToggleAudio: @escaping () -> Void, onToggleVideo: @escaping () -> Void) {
        audioButton = CircleToggleButton(onSymbol: "mic.fill", offSymbol: "mic.slash.fill", action: onToggleAudio)
        videoButton = CircleToggleButton(onSymbol: "video.fill", offSymbol: "video.slash.fill", action: onToggleVideo)

        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 60))

        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 20
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Audio column
        let audioColumn = NSStackView()
        audioColumn.orientation = .vertical
        audioColumn.spacing = 2
        audioColumn.alignment = .centerX
        configureLabel(audioLabel)
        audioColumn.addArrangedSubview(audioButton)
        audioColumn.addArrangedSubview(audioLabel)

        // Video column
        let videoColumn = NSStackView()
        videoColumn.orientation = .vertical
        videoColumn.spacing = 2
        videoColumn.alignment = .centerX
        configureLabel(videoLabel)
        videoColumn.addArrangedSubview(videoButton)
        videoColumn.addArrangedSubview(videoLabel)

        stack.addArrangedSubview(audioColumn)
        stack.addArrangedSubview(videoColumn)

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // Fixed height for the menu item view
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 60).isActive = true
    }

    private func configureLabel(_ label: NSTextField) {
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
    }

    func updateAudio(isOn: Bool, enabled: Bool) {
        audioButton.setState(isOn: isOn, enabled: enabled)
        audioLabel.stringValue = isOn ? "Mute" : "Unmute"
        audioLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    func updateVideo(isOn: Bool, enabled: Bool) {
        videoButton.setState(isOn: isOn, enabled: enabled)
        videoLabel.stringValue = isOn ? "Video" : "No Video"
        videoLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }
}

// MARK: - MenuBarController

/// Manages the menu bar status item (icon and dropdown menu).
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var deviceMenuItem: NSMenuItem!
    private var connectionMenuItem: NSMenuItem!
    private var configureDeviceMenuItem: NSMenuItem!
    private var toggleControlsItem: NSMenuItem!
    private var toggleControlsView: ToggleControlsView!
    private var launchAtLoginMenuItem: NSMenuItem!

    private(set) var currentStatus: SyncStatus = .webexNotRunning
    private var currentVideoState: WebexVideoState = .unknown

    /// Timestamp of last UI button click — suppresses polling overwrites briefly
    private var lastUIToggleTime: Date = .distantPast
    private let uiToggleCooldown: TimeInterval = 1.5

    /// Optimistic state set by UI clicks — used for rapid repeated clicks before polling catches up
    private var optimisticMuted: Bool?
    private var optimisticVideoOff: Bool?

    /// Per-button cooldown to prevent duplicate fires (time-based, not confirmation-based,
    /// because NSMenu's event tracking mode blocks poll timers)
    private var lastAudioClickTime: Date = .distantPast
    private var lastVideoClickTime: Date = .distantPast
    private let actionCooldown: TimeInterval = 0.5

    /// Whether we're in the UI cooldown period after a button click
    private var isInUICooldown: Bool {
        Date().timeIntervalSince(lastUIToggleTime) < uiToggleCooldown
    }

    /// Closures called when the user clicks toggle menu items
    var onToggleAudio: (() -> Void)?
    var onToggleVideo: (() -> Void)?

    /// Closure called when user clicks "Configure Device..."
    var onConfigureDevice: (() -> Void)?

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

        // Configure Device item (hidden by default, shown for unknown devices)
        configureDeviceMenuItem = NSMenuItem(title: "Configure Device...", action: #selector(configureDeviceClicked), keyEquivalent: "")
        configureDeviceMenuItem.target = self
        configureDeviceMenuItem.isHidden = true
        menu.addItem(configureDeviceMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Status
        statusMenuItem = NSMenuItem(title: "Status: Initializing...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Audio/Video circular toggle buttons
        toggleControlsView = ToggleControlsView(
            onToggleAudio: { [weak self] in
                guard let self = self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastAudioClickTime) >= self.actionCooldown else { return }
                self.lastAudioClickTime = now
                self.lastUIToggleTime = now
                let currentlyMuted = self.optimisticMuted ?? (self.currentStatus == .muted)
                let willBeMuted = !currentlyMuted
                self.optimisticMuted = willBeMuted
                self.toggleControlsView?.updateAudio(isOn: !willBeMuted, enabled: true)
                self.onToggleAudio?()
            },
            onToggleVideo: { [weak self] in
                guard let self = self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastVideoClickTime) >= self.actionCooldown else { return }
                self.lastVideoClickTime = now
                self.lastUIToggleTime = now
                let currentlyOff = self.optimisticVideoOff ?? (self.currentVideoState == .videoOff)
                let willBeOff = !currentlyOff
                self.optimisticVideoOff = willBeOff
                self.toggleControlsView?.updateVideo(isOn: !willBeOff, enabled: true)
                self.onToggleVideo?()
            }
        )
        toggleControlsItem = NSMenuItem()
        toggleControlsItem.view = toggleControlsView
        menu.addItem(toggleControlsItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        if LaunchAtLoginManager.isAvailable {
            launchAtLoginMenuItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        } else {
            launchAtLoginMenuItem.isEnabled = false
        }
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit WebexMuteSync", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        updateDisplay(status: .webexNotRunning)
    }

    /// Update device info in the menu dropdown.
    func updateDeviceInfo(connected: Bool, isUSB: Bool, productName: String?) {
        if connected {
            deviceMenuItem?.title = productName ?? "Speakerphone"
            connectionMenuItem?.title = isUSB ? "Connection: USB" : "Connection: Bluetooth (LED unavailable)"
        } else {
            deviceMenuItem?.title = "Device: Not connected"
            connectionMenuItem?.title = "Connection: —"
        }
    }

    /// Show or hide the "Configure Device..." menu item based on profile status.
    func updateProfileStatus(isKnown: Bool, hasDevice: Bool) {
        configureDeviceMenuItem?.isHidden = !hasDevice || isKnown
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
            statusText = "Speakerphone not connected"
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

        // Update circular toggle buttons (skip during UI cooldown to prevent poll overwrites)
        let inMeeting = (status == .muted || status == .unmuted)
        if !isInUICooldown {
            // Cooldown expired — clear optimistic state and sync from actual state
            optimisticMuted = nil
            optimisticVideoOff = nil

            switch status {
            case .muted:
                toggleControlsView?.updateAudio(isOn: false, enabled: true)
            case .unmuted:
                toggleControlsView?.updateAudio(isOn: true, enabled: true)
            default:
                toggleControlsView?.updateAudio(isOn: true, enabled: false)
            }

            if !inMeeting {
                toggleControlsView?.updateVideo(isOn: true, enabled: false)
                currentVideoState = .unknown
            }
        } else if !inMeeting {
            currentVideoState = .unknown
        }
    }

    /// Update the video menu item to reflect current video state
    func updateVideoState(_ state: WebexVideoState) {
        currentVideoState = state

        guard !isInUICooldown else { return }

        let inMeeting = (currentStatus == .muted || currentStatus == .unmuted)

        switch state {
        case .videoOn:
            toggleControlsView?.updateVideo(isOn: true, enabled: inMeeting)
        case .videoOff:
            toggleControlsView?.updateVideo(isOn: false, enabled: inMeeting)
        case .unknown:
            toggleControlsView?.updateVideo(isOn: true, enabled: false)
        }
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

    @objc private func configureDeviceClicked() {
        onConfigureDevice?()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLoginManager.toggle()
        launchAtLoginMenuItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
