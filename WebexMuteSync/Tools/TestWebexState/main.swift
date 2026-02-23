import AppKit
import ApplicationServices

/// CLI tool to continuously monitor and print Webex mute state.
/// Uses the same Accessibility API approach as WebexMonitor.
///
/// Requires Accessibility permission in System Settings.

print("=== Webex Mute State Monitor ===\n")

// Check accessibility permission
let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(options) {
    print("⚠️  Accessibility permission required!")
    print("Enable in: System Settings > Privacy & Security > Accessibility")
    print("Waiting for permission...\n")
}

let webexBundleIDs = ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]
let mutePatterns = ["Mute", "Unmute"]

func findWebexPID() -> pid_t? {
    for app in NSWorkspace.shared.runningApplications {
        if let bid = app.bundleIdentifier, webexBundleIDs.contains(bid) {
            return app.processIdentifier
        }
    }
    return nil
}

func axTitle(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func axDescription(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func axRole(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func axIsEnabled(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else {
        return true
    }
    return (value as? Bool) ?? true
}

func axChildren(of element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return nil
    }
    return value as? [AXUIElement]
}

// Detect state from menu bar
func detectFromMenuBar(pid: pid_t) -> String {
    let app = AXUIElementCreateApplication(pid)

    var menuBarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
          let menuBarRef = menuBarRef,
          let menuItems = axChildren(of: (menuBarRef as! AXUIElement)) else {
        return "NO_MENU_BAR"
    }

    // Print all top-level menu items for debugging
    let titles = menuItems.compactMap { axTitle(of: $0) }
    print("  Menu items: \(titles.joined(separator: ", "))")

    // Search for meeting-related menu
    let meetingMenuNames = ["Meeting", "Meetings & Calls"]

    for item in menuItems {
        guard let title = axTitle(of: item), meetingMenuNames.contains(where: { title.contains($0) }) else {
            continue
        }

        print("  Found menu: \"\(title)\"")

        // Look for mute item recursively
        if let state = findMuteInMenu(item, depth: 0) {
            return state
        }
    }

    return "NO_MUTE_MENU_FOUND"
}

func findMuteInMenu(_ element: AXUIElement, depth: Int) -> String? {
    guard depth < 5, let children = axChildren(of: element) else { return nil }

    for child in children {
        if let title = axTitle(of: child) {
            let indent = String(repeating: "  ", count: depth + 2)
            let enabled = axIsEnabled(child) ? "" : " [DISABLED]"
            print("\(indent)> \"\(title)\"\(enabled)")

            for pattern in mutePatterns {
                if title.contains(pattern) {
                    if !axIsEnabled(child) {
                        return "NO_MEETING (mute item disabled)"
                    }
                    if title.lowercased().contains("unmute") {
                        return "MUTED (menu says 'Unmute')"
                    } else {
                        return "UNMUTED (menu says 'Mute')"
                    }
                }
            }
        }

        if let result = findMuteInMenu(child, depth: depth + 1) {
            return result
        }
    }
    return nil
}

// Detect state from meeting window buttons
func detectFromWindow(pid: pid_t) -> String {
    let app = AXUIElementCreateApplication(pid)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else {
        return "NO_WINDOWS"
    }

    print("  Found \(windows.count) window(s)")

    for (i, window) in windows.enumerated() {
        let windowTitle = axTitle(of: window) ?? "(no title)"
        print("  Window \(i): \"\(windowTitle)\"")

        if let state = scanForMuteButton(window, depth: 0) {
            return state
        }
    }

    return "NO_MUTE_BUTTON_FOUND"
}

func scanForMuteButton(_ element: AXUIElement, depth: Int) -> String? {
    guard depth < 8 else { return nil }

    let role = axRole(of: element)
    let desc = axDescription(of: element)
    let title = axTitle(of: element)

    if role == kAXButtonRole as String {
        let text = [desc, title].compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("unmute") {
            return "MUTED (button says 'unmute')"
        } else if text.contains("mute") {
            return "UNMUTED (button says 'mute')"
        }
    }

    guard let children = axChildren(of: element) else { return nil }
    for child in children {
        if let result = scanForMuteButton(child, depth: depth + 1) {
            return result
        }
    }
    return nil
}

// Main monitoring loop
print("Monitoring Webex state every 1 second... Press Ctrl+C to stop.\n")

signal(SIGINT) { _ in
    print("\nStopping...")
    exit(0)
}

var lastState = ""

while true {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

    guard let pid = findWebexPID() else {
        let state = "NOT_RUNNING"
        if state != lastState {
            print("[\(timestamp)] Webex: \(state)")
            lastState = state
        }
        Thread.sleep(forTimeInterval: 2.0)
        continue
    }

    print("[\(timestamp)] Webex PID: \(pid)")

    let menuState = detectFromMenuBar(pid: pid)
    print("  Menu bar: \(menuState)")

    let windowState = detectFromWindow(pid: pid)
    print("  Window:   \(windowState)")

    let state = menuState.contains("MUTED") || menuState.contains("UNMUTED") ? menuState : windowState
    if state != lastState {
        print("  >>> STATE CHANGED: \(state)")
        lastState = state
    }

    print()
    Thread.sleep(forTimeInterval: 1.0)
}
