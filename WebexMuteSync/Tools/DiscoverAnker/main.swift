import Foundation
import IOKit
import IOKit.hid

/// CLI tool to discover Anker HID devices and inspect their interfaces.
/// Run with the Anker PowerConf S3 plugged in via USB.

print("=== Anker HID Device Discovery ===\n")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// Match all HID devices first, then filter
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard result == kIOReturnSuccess else {
    print("ERROR: Failed to open HID manager: \(result)")
    exit(1)
}

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    print("No HID devices found.")
    exit(0)
}

print("Found \(deviceSet.count) HID device(s)\n")

let ankerVID = 0x291A

// Helper to get a device property
func getProperty(_ device: IOHIDDevice, key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

func getIntProperty(_ device: IOHIDDevice, key: String) -> Int? {
    getProperty(device, key: key) as? Int
}

func getStringProperty(_ device: IOHIDDevice, key: String) -> String? {
    getProperty(device, key: key) as? String
}

// First pass: show all Anker devices
print("--- Anker Devices (VID 0x\(String(ankerVID, radix: 16, uppercase: true))) ---\n")

var ankerDevices: [IOHIDDevice] = []

for device in deviceSet {
    guard let vid = getIntProperty(device, key: kIOHIDVendorIDKey) else { continue }
    guard vid == ankerVID else { continue }

    ankerDevices.append(device)

    let pid = getIntProperty(device, key: kIOHIDProductIDKey) ?? 0
    let product = getStringProperty(device, key: kIOHIDProductKey) ?? "Unknown"
    let transport = getStringProperty(device, key: kIOHIDTransportKey) ?? "Unknown"
    let usagePage = getIntProperty(device, key: kIOHIDPrimaryUsagePageKey) ?? 0
    let usage = getIntProperty(device, key: kIOHIDPrimaryUsageKey) ?? 0
    let maxInputReport = getIntProperty(device, key: kIOHIDMaxInputReportSizeKey) ?? 0
    let maxOutputReport = getIntProperty(device, key: kIOHIDMaxOutputReportSizeKey) ?? 0
    let maxFeatureReport = getIntProperty(device, key: kIOHIDMaxFeatureReportSizeKey) ?? 0

    print("  Product:        \(product)")
    print("  VID:            0x\(String(vid, radix: 16, uppercase: true))")
    print("  PID:            0x\(String(pid, radix: 16, uppercase: true))")
    print("  Transport:      \(transport)")
    print("  Usage Page:     0x\(String(usagePage, radix: 16, uppercase: true)) (\(usagePageName(usagePage)))")
    print("  Usage:          0x\(String(usage, radix: 16, uppercase: true))")
    print("  Max Input:      \(maxInputReport) bytes")
    print("  Max Output:     \(maxOutputReport) bytes")
    print("  Max Feature:    \(maxFeatureReport) bytes")
    print()
}

if ankerDevices.isEmpty {
    print("  No Anker devices found!")
    print()
    print("  Make sure the Anker PowerConf S3 is:")
    print("    1. Plugged in via USB (not Bluetooth)")
    print("    2. Powered on")
    print()
    print("--- All HID Devices (for reference) ---\n")

    for device in deviceSet.sorted(by: {
        (getIntProperty($0, key: kIOHIDVendorIDKey) ?? 0) < (getIntProperty($1, key: kIOHIDVendorIDKey) ?? 0)
    }) {
        let vid = getIntProperty(device, key: kIOHIDVendorIDKey) ?? 0
        let pid = getIntProperty(device, key: kIOHIDProductIDKey) ?? 0
        let product = getStringProperty(device, key: kIOHIDProductKey) ?? "Unknown"
        let usagePage = getIntProperty(device, key: kIOHIDPrimaryUsagePageKey) ?? 0

        print("  0x\(String(vid, radix: 16, uppercase: true)):0x\(String(pid, radix: 16, uppercase: true))  " +
              "UP=0x\(String(usagePage, radix: 16, uppercase: true))  \(product)")
    }
} else {
    // Check for telephony interface
    print("--- Telephony Interface Check ---\n")
    let telephonyDevices = ankerDevices.filter {
        (getIntProperty($0, key: kIOHIDPrimaryUsagePageKey) ?? 0) == 0x0B
    }

    if let telDevice = telephonyDevices.first {
        let pid = getIntProperty(telDevice, key: kIOHIDProductIDKey) ?? 0
        print("  ✅ Telephony interface found!")
        print("  PID for Config.swift: 0x\(String(pid, radix: 16, uppercase: true))")
        print()
        print("  Update Config.swift with:")
        print("    static let ankerProductID: Int = 0x\(String(pid, radix: 16, uppercase: true))")
    } else {
        print("  ⚠️ No telephony interface (Usage Page 0x0B) found on Anker device.")
        print("  Available usage pages:")
        for device in ankerDevices {
            let up = getIntProperty(device, key: kIOHIDPrimaryUsagePageKey) ?? 0
            print("    0x\(String(up, radix: 16, uppercase: true)) (\(usagePageName(up)))")
        }
    }
}

print()
print("--- Report Descriptor Hint ---")
print()
print("To dump the full HID report descriptor, run:")
print("  ioreg -r -d 1 -w 0 -c IOHIDDevice | grep -A 20 'Anker'")
print()

IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

func usagePageName(_ page: Int) -> String {
    switch page {
    case 0x01: return "Generic Desktop"
    case 0x02: return "Simulation"
    case 0x05: return "Game"
    case 0x06: return "Generic Device"
    case 0x07: return "Keyboard/Keypad"
    case 0x08: return "LED"
    case 0x09: return "Button"
    case 0x0B: return "Telephony"
    case 0x0C: return "Consumer"
    case 0x0D: return "Digitizer"
    case 0xFF00...0xFFFF: return "Vendor-Defined"
    default: return "Unknown"
    }
}
