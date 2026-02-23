import Foundation
import IOKit
import IOKit.hid

/// CLI tool to test toggling the Anker PowerConf S3 mute LED.
/// Requires the device to be connected via USB.
///
/// Usage: TestLED [on|off|toggle]
///   on     - Turn mute LED on (red)
///   off    - Turn mute LED off
///   toggle - Toggle LED on/off every 2 seconds (default)
///
/// The device requires Off-Hook (0x17) to be set before Mute LED (0x09) responds.

let ankerVID = 0x291A
let ankerPID = 0x3302

print("=== Anker Mute LED Test ===\n")

let mode: String
if CommandLine.arguments.count > 1 {
    mode = CommandLine.arguments[1].lowercased()
} else {
    mode = "toggle"
}

guard ["on", "off", "toggle"].contains(mode) else {
    print("Usage: TestLED [on|off|toggle]")
    exit(1)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: ankerVID,
    kIOHIDProductIDKey as String: ankerPID,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    print("ERROR: Failed to open HID manager: \(openResult)")
    exit(1)
}

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      let device = deviceSet.first else {
    print("ERROR: No Anker device found. Is it plugged in via USB?")
    exit(1)
}

let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
print("Found device: \(product)")

// Find Off-Hook and Mute output elements
guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
    print("ERROR: Could not enumerate device elements")
    exit(1)
}

var offHookElement: IOHIDElement?
var muteElement: IOHIDElement?

for e in elements {
    guard IOHIDElementGetType(e) == kIOHIDElementTypeOutput else { continue }
    switch IOHIDElementGetUsage(e) {
    case 0x17: offHookElement = e
    case 0x09: muteElement = e
    default: break
    }
}

guard let offHookEl = offHookElement, let muteEl = muteElement else {
    print("ERROR: Could not find Off-Hook/Mute LED elements")
    exit(1)
}

print("Found Off-Hook and Mute LED elements\n")

func setOffHook(_ on: Bool) {
    let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, offHookEl, 0, on ? 1 : 0)
    IOHIDDeviceSetValue(device, offHookEl, val)
}

func setMuteLED(_ on: Bool) {
    let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, muteEl, 0, on ? 1 : 0)
    let r = IOHIDDeviceSetValue(device, muteEl, val)
    if r == kIOReturnSuccess {
        print("  Mute LED \(on ? "ON (red)" : "OFF")")
    } else {
        print("  Mute LED FAILED (error: \(r))")
    }
}

// Always set Off-Hook first
setOffHook(true)
print("  Off-Hook set (simulating active call)")

switch mode {
case "on":
    setMuteLED(true)
case "off":
    setMuteLED(false)
case "toggle":
    print("\nToggling mute LED every 2 seconds... Press Ctrl+C to stop.\n")
    var ledOn = false
    signal(SIGINT) { _ in
        print("\nStopping...")
        exit(0)
    }
    while true {
        ledOn.toggle()
        setMuteLED(ledOn)
        Thread.sleep(forTimeInterval: 2.0)
    }
default:
    break
}

IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
