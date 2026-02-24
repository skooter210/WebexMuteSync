import Foundation

/// Represents the overall sync status for the menu bar display
enum SyncStatus: Equatable {
    case idle              // No meeting active
    case syncing           // Actively syncing mute state
    case muted             // In meeting, muted
    case unmuted           // In meeting, unmuted
    case ringing           // Incoming call
    case deviceDisconnected // Speakerphone not connected
    case webexNotRunning   // Webex not running
    case usbRequired       // Device connected via Bluetooth, need USB
}

/// Delegate for sync status changes (used by MenuBarController)
protocol SyncEngineDelegate: AnyObject {
    func syncEngine(_ engine: SyncEngine, didUpdateStatus status: SyncStatus)
    func syncEngine(_ engine: SyncEngine, deviceConnected: Bool, isUSB: Bool, productName: String?)
    func syncEngine(_ engine: SyncEngine, didUpdateVideoState state: WebexVideoState)
    func syncEngine(_ engine: SyncEngine, deviceProfileStatus isKnown: Bool, profile: DeviceProfile?)
}

/// Bidirectional sync coordinator between Webex mute state and speakerphone HID LED.
///
/// - Webex → Device: When WebexMonitor detects a state change, updates the LED.
/// - Device → Webex: When HIDDevice reports a button press, toggles Webex mute
///   and optimistically updates the LED.
/// - Uses a cooldown after button presses to prevent feedback loops.
final class SyncEngine {
    weak var delegate: SyncEngineDelegate?

    let webexMonitor = WebexMonitor()
    let hidDevice = HIDDevice()

    private(set) var status: SyncStatus = .webexNotRunning {
        didSet {
            if status != oldValue {
                delegate?.syncEngine(self, didUpdateStatus: status)

                // Update device info based on status
                switch status {
                case .deviceDisconnected:
                    delegate?.syncEngine(self, deviceConnected: false, isUSB: false, productName: nil)
                case .usbRequired:
                    delegate?.syncEngine(self, deviceConnected: true, isUSB: false, productName: hidDevice.productName)
                default:
                    if hidDevice.isConnected {
                        delegate?.syncEngine(self, deviceConnected: true, isUSB: hidDevice.isUSB, productName: hidDevice.productName)
                    }
                }
            }
        }
    }

    /// Timestamp of last device button press — used for cooldown
    private var lastButtonPressTime: Date = .distantPast

    /// Whether we're in the cooldown period after a button press
    private var isInCooldown: Bool {
        Date().timeIntervalSince(lastButtonPressTime) < Config.buttonPressCooldown
    }

    /// Last known mute state applied to the LED
    private var lastLEDState: Bool?

    /// Whether the ring LED is currently on
    private var ringLEDActive: Bool = false

    /// Timer to verify sync after cooldown expires
    private var postCooldownTimer: DispatchSourceTimer?

    /// Count consecutive noMeeting/notRunning states before clearing LED
    /// Prevents flicker from cache staleness during UI refreshes
    private var noMeetingCount: Int = 0
    private let noMeetingThreshold: Int = 5

    /// Whether sync is paused (e.g. while test panel is open)
    private(set) var isPaused: Bool = false

    // MARK: - Lifecycle

    func start() {
        webexMonitor.delegate = self
        hidDevice.delegate = self

        hidDevice.start()
        webexMonitor.start()

        updateStatus()
    }

    func stop() {
        webexMonitor.stop()
        hidDevice.stop()
    }

    // MARK: - Pause / Resume (for test panel)

    /// Pause sync so the test panel can control the device directly.
    func pauseSync() {
        isPaused = true
        print("[Sync] Paused for device configuration")
    }

    /// Resume normal sync after the test panel closes.
    func resumeSync() {
        isPaused = false
        print("[Sync] Resumed")
        // Re-sync current state to device
        syncWebexStateToDevice(webexMonitor.currentState)
        updateStatus()
    }

    // MARK: - Public Actions

    /// Toggle Webex audio mute from the menu bar
    func toggleWebexMute() {
        webexMonitor.toggleMute()
    }

    /// Toggle Webex video from the menu bar
    func toggleWebexVideo() {
        webexMonitor.toggleVideo()
    }

    // MARK: - Status

    private func updateStatus() {
        if !hidDevice.isConnected && hidDevice.isBluetoothConnected {
            status = .usbRequired
        } else if !hidDevice.isConnected {
            status = .deviceDisconnected
        } else if hidDevice.isConnected && !hidDevice.isUSB {
            status = .usbRequired
        } else {
            switch webexMonitor.currentState {
            case .notRunning:
                status = .webexNotRunning
            case .noMeeting:
                status = .idle
            case .ringing:
                status = .ringing
            case .muted:
                status = .muted
            case .unmuted:
                status = .unmuted
            }
        }
    }

    // MARK: - Sync: Webex → Device

    private func syncWebexStateToDevice(_ state: WebexState) {
        guard hidDevice.isConnected, hidDevice.isUSB else { return }
        guard !isPaused else { return }

        // Don't update LED during cooldown (button press already handled it)
        guard !isInCooldown else { return }

        // Stop ring LED when transitioning away from ringing
        if state != .ringing && ringLEDActive {
            hidDevice.setRingLED(false)
            ringLEDActive = false
        }

        switch state {
        case .ringing:
            noMeetingCount = 0
            if !ringLEDActive {
                hidDevice.setRingLED(true)
                ringLEDActive = true
            }
        case .muted:
            noMeetingCount = 0
            if lastLEDState != true {
                hidDevice.setMuteLED(true)
                lastLEDState = true
            }
        case .unmuted:
            noMeetingCount = 0
            if lastLEDState != false {
                hidDevice.setMuteLED(false)
                lastLEDState = false
            }
        case .noMeeting, .notRunning:
            noMeetingCount += 1
            // Require several consecutive no-meeting polls before clearing LED
            // to avoid flicker from cache staleness during UI refreshes
            if noMeetingCount >= noMeetingThreshold {
                if lastLEDState != nil && lastLEDState != false {
                    hidDevice.clearCallState()
                    lastLEDState = false
                }
            }
        }
    }

    // MARK: - Sync: Device → Webex

    private func handleDeviceMuteToggle(wantsMuted: Bool) {
        guard !isPaused else { return }

        lastButtonPressTime = Date()

        let state = webexMonitor.currentState

        guard state == .muted || state == .unmuted else { return }

        let currentlyMuted = (state == .muted)

        // Only press the button if Webex isn't already in the desired state
        if wantsMuted != currentlyMuted {
            webexMonitor.toggleMute()
        }

        // Set LED to match desired state
        hidDevice.setMuteLED(wantsMuted)
        lastLEDState = wantsMuted

        // Schedule a verification after cooldown to catch any drift
        schedulePostCooldownVerification()
    }

    /// Re-syncs LED with actual Webex state after the cooldown window expires
    private func schedulePostCooldownVerification() {
        postCooldownTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Config.buttonPressCooldown + 0.3)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let state = self.webexMonitor.currentState
            let shouldBeMuted: Bool?
            switch state {
            case .muted: shouldBeMuted = true
            case .unmuted: shouldBeMuted = false
            default: shouldBeMuted = nil
            }
            if let shouldBeMuted = shouldBeMuted, shouldBeMuted != self.lastLEDState {
                self.hidDevice.setMuteLED(shouldBeMuted)
                self.lastLEDState = shouldBeMuted
            }
            self.updateStatus()
        }
        timer.resume()
        postCooldownTimer = timer
    }
}

// MARK: - WebexMonitorDelegate

extension SyncEngine: WebexMonitorDelegate {
    func webexMonitor(_ monitor: WebexMonitor, didDetectState state: WebexState) {
        syncWebexStateToDevice(state)
        updateStatus()
    }

    func webexMonitor(_ monitor: WebexMonitor, didDetectVideoState state: WebexVideoState) {
        delegate?.syncEngine(self, didUpdateVideoState: state)
    }
}

// MARK: - HIDDeviceDelegate

extension SyncEngine: HIDDeviceDelegate {
    func hidDeviceDidConnect() {
        updateStatus()
        // Sync current Webex state to the newly connected device
        syncWebexStateToDevice(webexMonitor.currentState)
        // Notify delegate about profile status
        delegate?.syncEngine(self,
                             deviceProfileStatus: hidDevice.isKnownProfile,
                             profile: hidDevice.activeProfile)
    }

    func hidDeviceDidDisconnect() {
        lastLEDState = nil
        ringLEDActive = false
        updateStatus()
        // Notify delegate that no profile is active
        delegate?.syncEngine(self, deviceProfileStatus: true, profile: nil)
    }

    func hidDeviceMuteToggled(wantsMuted: Bool) {
        handleDeviceMuteToggle(wantsMuted: wantsMuted)
    }
}
