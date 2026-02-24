import Foundation
import IOKit
import IOKit.hid
import IOBluetooth

/// Describes a single HID output element for the test panel.
struct HIDOutputElementInfo {
    let usagePage: UInt32
    let usage: UInt32
    let reportID: UInt32
    let element: IOHIDElement
}

/// Raw input event forwarded by the raw input callback.
struct HIDRawInputEvent {
    let usagePage: UInt32
    let usage: UInt32
    let intValue: Int
    let isRelative: Bool
}

/// Delegate protocol for HID device events
protocol HIDDeviceDelegate: AnyObject {
    func hidDeviceDidConnect()
    func hidDeviceDidDisconnect()
    /// Called when the device's mute toggle changes state.
    /// - Parameter wantsMuted: `true` if user pressed to mute, `false` to unmute.
    func hidDeviceMuteToggled(wantsMuted: Bool)
}

/// Manages IOKit HID communication with USB speakerphones.
///
/// LED control uses `IOHIDDeviceSetValue` on individual HID elements.
/// Element usages are driven by the active `DeviceProfile`.
///
/// Mute button input uses `IOHIDDeviceRegisterInputValueCallback`.
/// Handles both absolute and relative input modes via `IOHIDElementIsRelative`.
final class HIDDevice {
    weak var delegate: HIDDeviceDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Cached output elements by usage ID
    private var offHookElement: IOHIDElement?
    private var muteElement: IOHIDElement?
    private var ringElement: IOHIDElement?

    /// Cached Phone Mute input element — used for relative vs absolute check
    private var phoneMuteElement: IOHIDElement?

    private var lastButtonPressTime: Date = .distantPast
    private let debounceInterval = Config.buttonDebounceInterval

    /// The active device profile (built-in, user-saved, or generic)
    private(set) var activeProfile: DeviceProfile?

    /// Whether the active profile is a known (built-in or user-saved) profile vs generic fallback
    var isKnownProfile: Bool {
        guard let profile = activeProfile else { return false }
        return profile.isBuiltIn || ProfileManager.shared.profileFor(
            vendorID: profile.vendorID, productID: profile.productID
        ) != nil
    }

    /// Whether the speakerphone is currently connected via USB HID
    var isConnected: Bool { device != nil }

    /// Whether the current connection is via USB (vs Bluetooth)
    private(set) var isUSB: Bool = false

    /// Product name reported by the HID device (e.g. "Anker PowerConf S3")
    private(set) var productName: String?

    /// Whether the speakerphone is connected via Bluetooth (no HID/LED control)
    var isBluetoothConnected: Bool {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return false }
        // Check by connected device's product name if we know it, otherwise check common prefixes
        if let name = productName {
            let prefix = String(name.prefix(15))
            return devices.contains { $0.isConnected() && ($0.name ?? "").contains(prefix) }
        }
        return devices.contains { $0.isConnected() && ($0.name ?? "").contains("PowerConf") }
    }

    /// Whether we've set Off-Hook to simulate an active call
    private var offHookActive: Bool = false

    /// Last mute bit state for edge detection (absolute devices like S3)
    private var lastMuteBitState: Bool = false

    /// Last mute LED state — used by relative devices (S500) to infer desired state
    private(set) var lastMuteLEDState: Bool = false

    /// Raw input callback for the test panel — when set, ALL input values are forwarded here
    private var rawInputCallback: ((HIDRawInputEvent) -> Void)?

    // MARK: - Lifecycle

    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Match ALL HID devices — hasTelephonyOutput guard in handleDeviceConnected filters
        IOHIDManagerSetDeviceMatching(mgr, nil)

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
        phoneMuteElement = nil
        offHookActive = false
        productName = nil
        activeProfile = nil
        rawInputCallback = nil
    }

    // MARK: - LED Control

    /// Sets the mute LED on the device.
    ///
    /// If the profile requires Off-Hook, sets that first (simulating an active call).
    ///
    /// - Parameter muted: `true` to turn on the red mute LED, `false` to turn it off.
    /// - Returns: `true` if the value was set successfully.
    @discardableResult
    func setMuteLED(_ muted: Bool) -> Bool {
        guard let device = device, isUSB else {
            return false
        }
        guard let muteEl = muteElement else {
            return false
        }

        // Ensure Off-Hook is active if the profile requires it
        if let profile = activeProfile, profile.requiresOffHook, !offHookActive {
            guard let offHookEl = offHookElement else { return false }
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
        if result == kIOReturnSuccess {
            lastMuteLEDState = muted
        }
        return result == kIOReturnSuccess
    }

    /// Clears Off-Hook state (call ended). Turns off mute LED as a side effect.
    func clearCallState() {
        guard let device = device, let offHookEl = offHookElement else { return }
        let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, offHookEl, 0, 0)
        IOHIDDeviceSetValue(device, offHookEl, val)
        offHookActive = false
        lastMuteLEDState = false
    }

    /// Sets the Ring LED (blinking green) on the device.
    ///
    /// Like the mute LED, requires Off-Hook to be active first (if profile says so).
    ///
    /// - Parameter ringing: `true` to start ringing, `false` to stop.
    /// - Returns: `true` if the value was set successfully.
    @discardableResult
    func setRingLED(_ ringing: Bool) -> Bool {
        guard let device = device, isUSB else { return false }
        guard let ringEl = ringElement else { return false }

        // Ensure Off-Hook is active if required
        if let profile = activeProfile, profile.requiresOffHook, !offHookActive {
            guard let offHookEl = offHookElement else { return false }
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

    // MARK: - Test Panel API

    /// Returns all output elements for the connected device (used by the test panel).
    func allOutputElements() -> [HIDOutputElementInfo] {
        guard let hidDevice = device else { return [] }
        guard let elements = IOHIDDeviceCopyMatchingElements(
            hidDevice, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return [] }

        return elements.compactMap { element in
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeOutput else { return nil }
            return HIDOutputElementInfo(
                usagePage: IOHIDElementGetUsagePage(element),
                usage: IOHIDElementGetUsage(element),
                reportID: IOHIDElementGetReportID(element),
                element: element
            )
        }
    }

    /// Set a specific element's value (used by the test panel).
    @discardableResult
    func setElementValue(_ element: IOHIDElement, value: Int) -> Bool {
        guard let device = device else { return false }
        let hidValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, value)
        return IOHIDDeviceSetValue(device, element, hidValue) == kIOReturnSuccess
    }

    /// Register a callback that receives ALL input values (bypassing mute-only filtering).
    /// Used by the test panel to discover which element is the mute button.
    func registerRawInputCallback(_ callback: @escaping (HIDRawInputEvent) -> Void) {
        rawInputCallback = callback
    }

    /// Unregister the raw input callback, returning to normal mute-only filtering.
    func unregisterRawInputCallback() {
        rawInputCallback = nil
    }

    // MARK: - Device Events

    private func handleDeviceConnected(_ hidDevice: IOHIDDevice) {
        // Don't replace an already-connected device
        guard device == nil else { return }

        // Read product name from the device
        let name = IOHIDDeviceGetProperty(hidDevice, kIOHIDProductKey as CFString) as? String

        // Only accept devices that have telephony output elements (Off-Hook 0x17)
        // This filters out keyboards, mice, and other non-speakerphone HID devices
        let elements = IOHIDDeviceCopyMatchingElements(
            hidDevice, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] ?? []

        let hasTelephonyOutput = elements.contains { element in
            IOHIDElementGetType(element) == kIOHIDElementTypeOutput &&
            IOHIDElementGetUsage(element) == 0x17  // Off-Hook
        }

        guard hasTelephonyOutput else { return }

        device = hidDevice
        productName = name

        // Determine if connected via USB by checking transport property
        isUSB = checkIsUSB(hidDevice)

        // Look up profile: built-in → user-saved → generic fallback
        let vid = IOHIDDeviceGetProperty(hidDevice, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let pid = IOHIDDeviceGetProperty(hidDevice, kIOHIDProductIDKey as CFString) as? Int ?? 0

        if let profile = ProfileManager.shared.profileFor(vendorID: vid, productID: pid) {
            activeProfile = profile
            print("[HID] Matched profile: \(profile.name) (built-in: \(profile.isBuiltIn))")
        } else {
            // Use generic with actual VID/PID
            activeProfile = DeviceProfile(
                name: name ?? "Unknown Speakerphone",
                vendorID: vid,
                productID: pid,
                offHookUsage: DeviceProfile.generic.offHookUsage,
                muteLEDUsage: DeviceProfile.generic.muteLEDUsage,
                ringLEDUsage: DeviceProfile.generic.ringLEDUsage,
                muteButtonUsagePage: DeviceProfile.generic.muteButtonUsagePage,
                muteButtonUsage: DeviceProfile.generic.muteButtonUsage,
                requiresOffHook: DeviceProfile.generic.requiresOffHook,
                isRelative: nil,
                isBuiltIn: false,
                createdAt: Date()
            )
            print("[HID] Using generic profile for: \(name ?? "unknown") (VID:\(String(format: "0x%04X", vid)) PID:\(String(format: "0x%04X", pid)))")
        }

        // Find output elements for LED control + Phone Mute input element
        cacheElements(hidDevice)

        // Register input value callback for mute button presses
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputValueCallback(
            hidDevice,
            { context, _, _, value in
                guard let context = context else { return }
                let me = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
                me.handleInputValue(value)
            },
            unmanagedSelf
        )

        if let name = name {
            print("[HID] Connected: \(name) (\(isUSB ? "USB" : "Bluetooth"))")
        }

        delegate?.hidDeviceDidConnect()
    }

    private func handleDeviceDisconnected(_ hidDevice: IOHIDDevice) {
        if device === hidDevice {
            device = nil
            isUSB = false
            offHookElement = nil
            muteElement = nil
            ringElement = nil
            phoneMuteElement = nil
            offHookActive = false
            productName = nil
            activeProfile = nil
            lastMuteBitState = false
            lastMuteLEDState = false
        }
        delegate?.hidDeviceDidDisconnect()
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let isRelative = IOHIDElementIsRelative(element)

        // If raw callback is registered (test panel mode), forward everything
        if let rawCallback = rawInputCallback {
            rawCallback(HIDRawInputEvent(
                usagePage: usagePage,
                usage: usage,
                intValue: intValue,
                isRelative: isRelative
            ))
            return  // Don't process normally while in test panel mode
        }

        // Normal mode: only process the mute button as defined by the profile
        guard let profile = activeProfile else { return }
        guard usagePage == UInt32(profile.muteButtonUsagePage) &&
              usage == UInt32(profile.muteButtonUsage) else { return }

        // Determine relative mode: profile override or auto-detect
        let effectiveRelative = profile.isRelative ?? isRelative

        let wantsMuted: Bool

        if effectiveRelative {
            // Relative device (S500): pulse on press (1), ignore release (0)
            guard intValue == 1 else { return }

            // Debounce
            let now = Date()
            guard now.timeIntervalSince(lastButtonPressTime) >= debounceInterval else { return }

            // Toggle: infer desired state from current LED state
            wantsMuted = !lastMuteLEDState
        } else {
            // Absolute device (S3): value reflects the new state
            let muteActive = (intValue == 1)

            // Edge detection — only fire on state change
            guard muteActive != lastMuteBitState else { return }
            lastMuteBitState = muteActive

            // Debounce
            let now = Date()
            guard now.timeIntervalSince(lastButtonPressTime) >= debounceInterval else { return }

            wantsMuted = muteActive
        }

        lastButtonPressTime = Date()
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.hidDeviceMuteToggled(wantsMuted: wantsMuted)
        }
    }

    // MARK: - Helpers

    private func cacheElements(_ hidDevice: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            hidDevice, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            return
        }

        guard let profile = activeProfile else { return }

        for element in elements {
            let type = IOHIDElementGetType(element)
            let usage = IOHIDElementGetUsage(element)
            let usagePage = IOHIDElementGetUsagePage(element)

            if type == kIOHIDElementTypeOutput {
                if let offHook = profile.offHookUsage, usage == UInt32(offHook) {
                    offHookElement = element
                }
                if usage == UInt32(profile.muteLEDUsage) {
                    muteElement = element
                }
                if let ring = profile.ringLEDUsage, usage == UInt32(ring) {
                    ringElement = element
                }
            } else if type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button {
                if usagePage == UInt32(profile.muteButtonUsagePage) &&
                   usage == UInt32(profile.muteButtonUsage) {
                    phoneMuteElement = element
                    let relStr = IOHIDElementIsRelative(element) ? "relative" : "absolute"
                    print("[HID] Phone Mute element: \(relStr)")
                }
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
