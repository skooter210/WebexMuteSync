import AppKit
import ApplicationServices

/// Represents the current state of Webex
enum WebexState: Equatable {
    case notRunning
    case noMeeting
    case ringing     // Incoming call (not yet answered)
    case muted
    case unmuted
}

/// Delegate protocol for Webex state changes
protocol WebexMonitorDelegate: AnyObject {
    func webexMonitor(_ monitor: WebexMonitor, didDetectState state: WebexState)
}

/// Monitors Webex mute state via macOS Accessibility API (AXUIElement).
/// Caches the mute button reference for fast polling — only does a full
/// tree walk when the cache is invalid.
final class WebexMonitor {
    weak var delegate: WebexMonitorDelegate?

    private(set) var currentState: WebexState = .notRunning
    private var pollTimer: Timer?

    /// Cached mute button element — avoids full tree walk on every poll
    private var cachedMuteButton: AXUIElement?
    private var cachedWebexPID: pid_t?
    private var cacheFailCount: Int = 0

    // MARK: - Lifecycle

    func start() {
        schedulePoll(interval: Config.noWebexPollInterval)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        invalidateCache()
    }

    // MARK: - Mute Toggle

    /// Toggle Webex mute by pressing the mute button via Accessibility API.
    /// Uses cached button reference for speed, falls back to fresh lookup.
    func toggleMute() {
        // Try cached button first (fast — single AX call)
        if let button = cachedMuteButton {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                print("[Webex] Pressed mute button via cached ref")
                return
            }
            // Cache stale, clear it
            invalidateCache()
        }

        // Find button fresh
        guard let pid = findWebexPID() else {
            print("[Webex] Cannot toggle mute — Webex not running")
            return
        }

        if let button = findMuteButtonInWindows(pid: pid) {
            cachedMuteButton = button
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                print("[Webex] Pressed mute button via fresh lookup")
            } else {
                print("[Webex] Failed to press mute button: \(result.rawValue)")
            }
            return
        }

        // Fallback: keystroke (works when Webex is focused)
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Config.muteShortcutKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Config.muteShortcutKeyCode, keyDown: false)
        keyDown?.flags = Config.muteShortcutModifiers
        keyUp?.flags = Config.muteShortcutModifiers
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)
        print("[Webex] Fallback: sent Cmd+Shift+M to Webex")
    }

    // MARK: - Polling

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    @objc private func poll() {
        let newState = detectState()

        if newState != currentState {
            let oldState = currentState
            currentState = newState
            print("[Webex] State changed: \(oldState) → \(newState)")
            delegate?.webexMonitor(self, didDetectState: newState)
        }

        // Adjust poll interval based on state
        let desiredInterval: TimeInterval
        switch newState {
        case .notRunning:
            desiredInterval = Config.noWebexPollInterval
        case .noMeeting:
            desiredInterval = Config.idlePollInterval
        case .ringing, .muted, .unmuted:
            desiredInterval = Config.activeMeetingPollInterval
        }

        if pollTimer?.timeInterval != desiredInterval {
            schedulePoll(interval: desiredInterval)
        }
    }

    // MARK: - State Detection

    private func detectState() -> WebexState {
        guard let pid = findWebexPID() else {
            invalidateCache()
            return .notRunning
        }

        // If PID changed, invalidate cache
        if pid != cachedWebexPID {
            invalidateCache()
            cachedWebexPID = pid
        }

        // Fast path: read cached button's description directly
        if let button = cachedMuteButton {
            if let state = readMuteState(from: button) {
                cacheFailCount = 0
                return state
            }
            // Cache invalid — button gone or meeting ended
            cacheFailCount += 1
            if cacheFailCount > 2 {
                invalidateCache()
            }
        }

        // Slow path: find the mute button in the window tree
        if let button = findMuteButtonInWindows(pid: pid) {
            cachedMuteButton = button
            cacheFailCount = 0
            if let state = readMuteState(from: button) {
                return state
            }
        }

        // Only check for incoming call when not already in a meeting
        // (avoids expensive tree walk every poll during active calls)
        if hasIncomingCallWindow(pid: pid) {
            return .ringing
        }

        return .noMeeting
    }

    /// Read mute state from a cached button element (very fast — single AX call)
    private func readMuteState(from button: AXUIElement) -> WebexState? {
        // Read the button's description which changes between "mute" and "unmute"
        let desc = axDescription(of: button)
        let title = axTitle(of: button)
        let text = [desc, title].compactMap { $0 }.joined(separator: " ").lowercased()

        // Check it's still a mute-related button
        guard text.contains("mute") else { return nil }

        if text.contains("unmute") {
            return .muted
        } else {
            return .unmuted
        }
    }

    // MARK: - Incoming Call Detection

    /// Checks if Webex has an incoming call window by looking for Answer/Accept/Decline buttons.
    private func hasIncomingCallWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows {
            if hasIncomingCallButton(window, depth: 0) {
                return true
            }
        }
        return false
    }

    /// Recursively search for Answer/Accept/Decline buttons in an element tree.
    private func hasIncomingCallButton(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 10 else { return false }

        let role = axRole(of: element)

        if role == kAXButtonRole as String {
            let desc = axDescription(of: element)
            let title = axTitle(of: element)
            let text = [desc, title].compactMap { $0 }.joined(separator: " ").lowercased()
            if text.contains("answer") || text.contains("accept") || text.contains("decline") {
                return true
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children {
            if hasIncomingCallButton(child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    // MARK: - Button Discovery

    private func findMuteButtonInWindows(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            if let button = findMuteButtonElement(window, depth: 0) {
                return button
            }
        }
        return nil
    }

    /// Recursively find the mute/unmute button in an element tree
    private func findMuteButtonElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }

        let role = axRole(of: element)

        if role == kAXButtonRole as String {
            let desc = axDescription(of: element)
            let title = axTitle(of: element)
            let text = [desc, title].compactMap { $0 }.joined(separator: " ").lowercased()
            if text.contains("unmute") || text.contains("mute") {
                return element
            }
        }

        // Only recurse into groups/containers, skip other leaf elements
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let button = findMuteButtonElement(child, depth: depth + 1) {
                return button
            }
        }
        return nil
    }

    // MARK: - Cache Management

    private func invalidateCache() {
        cachedMuteButton = nil
        cachedWebexPID = nil
        cacheFailCount = 0
    }

    // MARK: - Accessibility Helpers

    private func axTitle(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axDescription(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Process Discovery

    private func findWebexPID() -> pid_t? {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               (bundleID == Config.webexBundleID || bundleID == Config.webexBundleIDAlt) {
                return app.processIdentifier
            }
        }
        return nil
    }
}
