import AppKit
import CoreGraphics

// Sniff all system events to see what the Anker mute button sends over Bluetooth.
// Press the mute button on the Anker while connected via BT and watch the output.

setbuf(stdout, nil)
print("Listening for all system events... Press Anker mute button over Bluetooth.")
print("Press Ctrl+C to stop.\n")

// Monitor system-defined events (media keys, etc.)
NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
    let subtype = event.subtype.rawValue
    let data1 = event.data1
    let data2 = event.data2
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = data1 & 0x0000FFFF
    let keyState = (keyFlags & 0xFF00) >> 8  // 0x0A = down, 0x0B = up
    print("[SystemDefined] subtype=\(subtype) keyCode=\(keyCode) keyState=0x\(String(keyState, radix: 16)) data1=0x\(String(data1, radix: 16)) data2=0x\(String(data2, radix: 16))")
}

// Monitor all key events
NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
    print("[Key] type=\(event.type.rawValue) keyCode=\(event.keyCode) chars=\(event.characters ?? "nil")")
}

// Also try a CGEvent tap for lower-level events
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    print("[CGEvent] type=\(type.rawValue) keycode=\(keycode) flags=\(event.flags.rawValue)")
    return Unmanaged.passRetained(event)
}

let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) |
    (1 << 14) |  // NX_SYSDEFINED
    (1 << CGEventType.flagsChanged.rawValue)

if let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: eventMask,
    callback: eventTapCallback,
    userInfo: nil
) {
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("CGEvent tap installed.\n")
} else {
    print("Warning: Could not create CGEvent tap (need Accessibility permission).\n")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
