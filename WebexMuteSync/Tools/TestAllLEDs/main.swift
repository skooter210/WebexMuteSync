import Foundation
import IOKit
import IOKit.hid

/// Test all output elements on the Anker PowerConf S3 to find LED behaviors.
/// Sets Off-Hook first, then activates each output element one at a time.

let ankerVID = 0x291A
let ankerPID = 0x3302

setbuf(stdout, nil)
print("=== Anker All LED Test ===\n")

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
print("Found device: \(product)\n")

guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
    print("ERROR: Could not enumerate device elements")
    exit(1)
}

// Collect all output elements
var outputElements: [(element: IOHIDElement, usage: UInt32, usagePage: UInt32, reportID: UInt32)] = []

for e in elements {
    guard IOHIDElementGetType(e) == kIOHIDElementTypeOutput else { continue }
    let usage = IOHIDElementGetUsage(e)
    let usagePage = IOHIDElementGetUsagePage(e)
    let reportID = IOHIDElementGetReportID(e)
    outputElements.append((e, usage, usagePage, reportID))
    print("  Output element: UsagePage=0x\(String(usagePage, radix: 16)) Usage=0x\(String(usage, radix: 16)) ReportID=\(reportID)")
}

print("\nFound \(outputElements.count) output elements.\n")

func setValue(_ element: IOHIDElement, _ value: Int) {
    let val = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, value)
    let r = IOHIDDeviceSetValue(device, element, val)
    if r != kIOReturnSuccess {
        print("    FAILED (error: \(r))")
    }
}

// Find Off-Hook element
guard let offHookEl = outputElements.first(where: { $0.usage == 0x17 })?.element else {
    print("ERROR: No Off-Hook element found")
    exit(1)
}

// Set Off-Hook first
print("Setting Off-Hook ON (required for LEDs)...")
setValue(offHookEl, 1)
Thread.sleep(forTimeInterval: 0.5)

// Test each non-Off-Hook element one at a time
let testElements = outputElements.filter { $0.usage != 0x17 }

for (i, el) in testElements.enumerated() {
    print("\n[\(i+1)/\(testElements.count)] Testing Usage=0x\(String(el.usage, radix: 16)) (UsagePage=0x\(String(el.usagePage, radix: 16)), ReportID=\(el.reportID))")
    print("  → Setting ON... watch the device for 3 seconds")
    setValue(el.element, 1)
    Thread.sleep(forTimeInterval: 3.0)
    print("  → Setting OFF")
    setValue(el.element, 0)
    Thread.sleep(forTimeInterval: 1.0)
}

// Clean up
print("\nClearing Off-Hook...")
setValue(offHookEl, 0)

print("\nDone!")
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
