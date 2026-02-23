import Foundation

/// Represents the overall sync status for the menu bar display
enum SyncStatus: Equatable {
    case idle              // No meeting active
    case syncing           // Actively syncing mute state
    case muted             // In meeting, muted
    case unmuted           // In meeting, unmuted
    case ringing           // Incoming call
    case deviceDisconnected // Anker not connected
    case webexNotRunning   // Webex not running
    case usbRequired       // Device connected via Bluetooth, need USB
}

/// Delegate for sync status changes (used by MenuBarController)
protocol SyncEngineDelegate: AnyObject {
    func syncEngine(_ engine: SyncEngine, didUpdateStatus status: SyncStatus)
    func syncEngine(_ engine: SyncEngine, deviceConnected: Bool, isUSB: Bool)
}

/// Bidirectional sync coordinator between Webex mute state and Anker HID LED.
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
                    delegate?.syncEngine(self, deviceConnected: false, isUSB: false)
                case .usbRequired:
                    delegate?.syncEngine(self, deviceConnected: true, isUSB: false)
                default:
                    if hidDevice.isConnected {
                        delegate?.syncEngine(self, deviceConnected: true, isUSB: hidDevice.isUSB)
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

    /// Count consecutive noMeeting/notRunning states before clearing LED
    /// Prevents flicker from cache staleness during UI refreshes
    private var noMeetingCount: Int = 0
    private let noMeetingThreshold: Int = 5

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

        // Don't update LED during cooldown (button press already handled it)
        guard !isInCooldown else {
            print("[Sync] Skipping LED update during cooldown")
            return
        }

        // Stop ring LED when transitioning away from ringing
        if state != .ringing && ringLEDActive {
            hidDevice.setRingLED(false)
            ringLEDActive = false
            print("[Sync] Webex→Device: ring LED OFF")
        }

        switch state {
        case .ringing:
            noMeetingCount = 0
            if !ringLEDActive {
                hidDevice.setRingLED(true)
                ringLEDActive = true
                print("[Sync] Webex→Device: ring LED ON (incoming call)")
            }
        case .muted:
            noMeetingCount = 0
            if lastLEDState != true {
                hidDevice.setMuteLED(true)
                lastLEDState = true
                print("[Sync] Webex→Device: LED ON (muted)")
            }
        case .unmuted:
            noMeetingCount = 0
            if lastLEDState != false {
                hidDevice.setMuteLED(false)
                lastLEDState = false
                print("[Sync] Webex→Device: LED OFF (unmuted)")
            }
        case .noMeeting, .notRunning:
            noMeetingCount += 1
            // Require several consecutive no-meeting polls before clearing LED
            // to avoid flicker from cache staleness during UI refreshes
            if noMeetingCount >= noMeetingThreshold {
                if lastLEDState != nil && lastLEDState != false {
                    hidDevice.clearCallState()
                    lastLEDState = false
                    print("[Sync] Webex→Device: call state cleared (no meeting/not running)")
                }
            }
        }
    }

    // MARK: - Sync: Device → Webex

    private func handleDeviceMuteToggle(wantsMuted: Bool) {
        lastButtonPressTime = Date()

        let state = webexMonitor.currentState
        print("[Sync] Device toggle: wants \(wantsMuted ? "muted" : "unmuted"), Webex is \(state)")

        guard state == .muted || state == .unmuted else {
            print("[Sync] Device toggle ignored — no active meeting")
            return
        }

        let currentlyMuted = (state == .muted)

        // Only press the button if Webex isn't already in the desired state
        if wantsMuted != currentlyMuted {
            webexMonitor.toggleMute()
            print("[Sync] Toggled Webex to \(wantsMuted ? "muted" : "unmuted")")
        } else {
            print("[Sync] Webex already \(wantsMuted ? "muted" : "unmuted"), no toggle needed")
        }

        // Set LED to match desired state
        hidDevice.setMuteLED(wantsMuted)
        lastLEDState = wantsMuted
        print("[Sync] LED \(wantsMuted ? "ON" : "OFF")")
    }
}

// MARK: - WebexMonitorDelegate

extension SyncEngine: WebexMonitorDelegate {
    func webexMonitor(_ monitor: WebexMonitor, didDetectState state: WebexState) {
        syncWebexStateToDevice(state)
        updateStatus()
    }
}

// MARK: - HIDDeviceDelegate

extension SyncEngine: HIDDeviceDelegate {
    func hidDeviceDidConnect() {
        print("[Sync] Device connected")
        updateStatus()
        // Sync current Webex state to the newly connected device
        syncWebexStateToDevice(webexMonitor.currentState)
    }

    func hidDeviceDidDisconnect() {
        print("[Sync] Device disconnected")
        lastLEDState = nil
        ringLEDActive = false
        updateStatus()
    }

    func hidDeviceMuteToggled(wantsMuted: Bool) {
        handleDeviceMuteToggle(wantsMuted: wantsMuted)
    }
}
