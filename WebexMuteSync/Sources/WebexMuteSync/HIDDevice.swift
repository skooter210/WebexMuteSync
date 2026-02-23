import Foundation
import IOKit
import IOKit.hid
import IOBluetooth

/// Delegate protocol for HID device events
protocol HIDDeviceDelegate: AnyObject {
    func hidDeviceDidConnect()
    func hidDeviceDidDisconnect()
    /// Called when the device's mute toggle changes state.
    /// The device is a toggle switch, not momentary — each press sends the NEW state.
    /// - Parameter wantsMuted: `true` if user pressed to mute, `false` to unmute.
    func hidDeviceMuteToggled(wantsMuted: Bool)
}

/// Manages IOKit HID communication with the Anker PowerConf S3 speakerphone.
///
/// LED control requires setting individual HID elements via `IOHIDDeviceSetValue`:
/// - The device requires Off-Hook (0x17) = ON to simulate an active call
/// - Then Mute (0x09) = ON/OFF controls the red mute LED
/// - Ring (0x18) controls blinking green for incoming calls
///
/// Mute button input arrives on Report ID 2, bit 3 (Phone Mute usage 0x2F).
final class HIDDevice {
    weak var delegate: HIDDeviceDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputReportBufferPtr: UnsafeMutablePointer<UInt8>?

    /// Cached output elements by usage ID
    private var offHookElement: IOHIDElement?   // Usage 0x17
    private var muteElement: IOHIDElement?       // Usage 0x09
    private var ringElement: IOHIDElement?       // Usage 0x18

    private var lastButtonPressTime: Date = .distantPast
    private let debounceInterval = Config.buttonDebounceInterval

    /// Whether the Anker device is currently connected via USB HID
    var isConnected: Bool { device != nil }

    /// Whether the current connection is via USB (vs Bluetooth)
    private(set) var isUSB: Bool = false

    /// Whether the Anker is connected via Bluetooth (no HID/LED control)
    var isBluetoothConnected: Bool {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return false }
        return devices.contains { $0.isConnected() && ($0.name ?? "").contains("Anker PowerConf") }
    }

    /// Whether we've set Off-Hook to simulate an active call
    private var offHookActive: Bool = false

    // MARK: - Lifecycle

    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Match Anker device by VID/PID
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: Config.ankerVendorID,
            kIOHIDProductIDKey as String: Config.ankerProductID,
        ]

        IOHIDManagerSetDeviceMatching(mgr, matchDict as CFDictionary)

        // Register connect/disconnect callbacks
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let me = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
            me.handleDeviceConnected(device)
        }, unmanagedSelf)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let me = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
            me.handleDeviceDisconnected(device)
        }, unmanagedSelf)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            print("[HID] Error: Failed to open HID manager: \(result)")
        }
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        device = nil
        offHookElement = nil
        muteElement = nil
        ringElement = nil
        offHookActive = false
        inputReportBufferPtr?.deallocate()
        inputReportBufferPtr = nil
    }

    // MARK: - LED Control

    /// Sets the mute LED on the Anker device.
    ///
    /// The device requires Off-Hook to be set first (simulating an active call)
    /// before the Mute LED will respond.
    ///
    /// - Parameter muted: `true` to turn on the red mute LED, `false` to turn it off.
    /// - Returns: `true` if the value was set successfully.
    @discardableResult
    func setMuteLED(_ muted: Bool) -> Bool {
        guard let device = device, isUSB else {
            return false
        }
        guard let muteEl = muteElement, let offHookEl = offHookElement else {
            return false
        }

        // Ensure Off-Hook is active (device needs to think it's in a call)
        if !offHookActive {
            let offHookVal = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, offHookEl, 0, 1)
            let r = IOHIDDeviceSetValue(device, offHookEl, offHookVal)
            if r == kIOReturnSuccess {
                offHookActive = true
            } else {
                return false
            }
        }

        // Set Mute LED
        let muteVal = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, muteEl, 0, muted ? 1 : 0)
        let result = IOHIDDeviceSetValue(device, muteEl, muteVal)
        return result == kIOReturnSuccess
    }

    /// Clears Off-Hook state (call ended). Turns off mute LED as a side effect.
    func clearCallState() {
        guard let device = device, let offHookEl = offHookElement else { return }
        let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, offHookEl, 0, 0)
        IOHIDDeviceSetValue(device, offHookEl, val)
        offHookActive = false
    }

    /// Sets the Ring LED (blinking green) on the Anker device.
    ///
    /// Like the mute LED, requires Off-Hook to be active first.
    ///
    /// - Parameter ringing: `true` to start ringing, `false` to stop.
    /// - Returns: `true` if the value was set successfully.
    @discardableResult
    func setRingLED(_ ringing: Bool) -> Bool {
        guard let device = device, isUSB else { return false }
        guard let ringEl = ringElement, let offHookEl = offHookElement else {
            return false
        }

        // Ensure Off-Hook is active
        if !offHookActive {
            let offHookVal = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, offHookEl, 0, 1)
            let r = IOHIDDeviceSetValue(device, offHookEl, offHookVal)
            if r == kIOReturnSuccess {
                offHookActive = true
            } else {
                return false
            }
        }

        let ringVal = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, ringEl, 0, ringing ? 1 : 0)
        let result = IOHIDDeviceSetValue(device, ringEl, ringVal)
        return result == kIOReturnSuccess
    }

    // MARK: - Device Events

    private func handleDeviceConnected(_ hidDevice: IOHIDDevice) {
        device = hidDevice

        // Determine if connected via USB by checking transport property
        isUSB = checkIsUSB(hidDevice)

        // Find output elements for LED control
        cacheOutputElements(hidDevice)

        // Register input report callback for mute button presses
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()

        let bufferSize = 64
        let bufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        bufferPtr.initialize(repeating: 0, count: bufferSize)
        inputReportBufferPtr = bufferPtr

        IOHIDDeviceRegisterInputReportCallback(
            hidDevice,
            bufferPtr,
            bufferSize,
            { context, _, _, type, reportID, report, reportLength in
                guard let context = context else { return }
                let me = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
                me.handleInputReport(reportID: UInt32(reportID), report: report, length: reportLength)
            },
            unmanagedSelf
        )

        delegate?.hidDeviceDidConnect()
    }

    private func handleDeviceDisconnected(_ hidDevice: IOHIDDevice) {
        if device === hidDevice {
            device = nil
            isUSB = false
            offHookElement = nil
            muteElement = nil
            ringElement = nil
            offHookActive = false
            inputReportBufferPtr?.deallocate()
            inputReportBufferPtr = nil
        }
        delegate?.hidDeviceDidDisconnect()
    }

    /// Previous state of the mute bit — for edge detection on periodic status reports
    private var lastMuteBitState: Bool = false

    private func handleInputReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>?, length: CFIndex) {
        guard let report = report else { return }

        // Only process telephony input reports (Report ID 2)
        guard length > Config.muteButtonByteIndex else { return }
        if Config.muteButtonReportID != 0 && reportID != UInt32(Config.muteButtonReportID) {
            return
        }

        let byte = report[Config.muteButtonByteIndex]
        let muteActive = (byte & Config.muteButtonBitMask) != 0

        // Only fire on rising edge: mute bit was 0, now 1
        // The device sends periodic status reports (not instantaneous button events),
        // so we must detect transitions rather than treating every report as a press.
        if muteActive != lastMuteBitState {
            lastMuteBitState = muteActive
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.hidDeviceMuteToggled(wantsMuted: muteActive)
            }
        }
    }

    // MARK: - Helpers

    private func cacheOutputElements(_ hidDevice: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            hidDevice, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            return
        }

        for element in elements {
            guard IOHIDElementGetType(element) == kIOHIDElementTypeOutput else { continue }
            let usage = IOHIDElementGetUsage(element)
            switch usage {
            case 0x17:  // Off-Hook
                offHookElement = element
            case 0x09:  // Mute
                muteElement = element
            case UInt32(Config.ringLEDUsage):  // Ring (0x18)
                ringElement = element
            default:
                break
            }
        }
    }

    private func checkIsUSB(_ hidDevice: IOHIDDevice) -> Bool {
        guard let transport = IOHIDDeviceGetProperty(hidDevice, kIOHIDTransportKey as CFString) as? String else {
            return true
        }
        let t = transport.lowercased()
        return t == "usb" || t == "spi"
    }
}
