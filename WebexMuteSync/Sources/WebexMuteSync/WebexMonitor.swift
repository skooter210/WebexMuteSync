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

/// Represents the current video state of Webex
enum WebexVideoState: Equatable {
    case unknown
    case videoOn
    case videoOff
}

/// Delegate protocol for Webex state changes
protocol WebexMonitorDelegate: AnyObject {
    func webexMonitor(_ monitor: WebexMonitor, didDetectState state: WebexState)
    func webexMonitor(_ monitor: WebexMonitor, didDetectVideoState state: WebexVideoState)
}

/// Monitors Webex mute state via macOS Accessibility API (AXUIElement).
/// Caches the mute button reference for fast polling — only does a full
/// tree walk when the cache is invalid.
final class WebexMonitor {
    weak var delegate: WebexMonitorDelegate?

    private(set) var currentState: WebexState = .notRunning
    private(set) var currentVideoState: WebexVideoState = .unknown
    private var pollTimer: Timer?

    /// Cached mute button element — avoids full tree walk on every poll
    private var cachedMuteButton: AXUIElement?
    private var cachedWebexPID: pid_t?
    private var cacheFailCount: Int = 0

    /// Cached video button element
    private var cachedVideoButton: AXUIElement?
    private var videoCacheFailCount: Int = 0

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
                // print("[Webex] Pressed mute button via cached ref")
                return
            }
            // Cache stale, clear it
            invalidateCache()
        }

        // Find button fresh
        guard let pid = findWebexPID() else {
            // print("[Webex] Cannot toggle mute — Webex not running")
            return
        }

        if let button = findMuteButtonInWindows(pid: pid) {
            cachedMuteButton = button
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                // print("[Webex] Pressed mute button via fresh lookup")
            } else {
                // print("[Webex] Failed to press mute button: \(result.rawValue)")
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
        // print("[Webex] Fallback: sent Cmd+Shift+M to Webex")
    }

    // MARK: - Video Toggle

    /// Toggle Webex video by pressing the video button via Accessibility API.
    func toggleVideo() {
        // Try cached button first
        if let button = cachedVideoButton {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success { return }
            cachedVideoButton = nil
        }

        guard let pid = findWebexPID() else { return }

        if let button = findVideoButtonInWindows(pid: pid) {
            cachedVideoButton = button
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success { return }
        }

        // Fallback: Cmd+Shift+V keystroke
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Config.videoShortcutKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Config.videoShortcutKeyCode, keyDown: false)
        keyDown?.flags = Config.videoShortcutModifiers
        keyUp?.flags = Config.videoShortcutModifiers
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)
    }

    // MARK: - Leave Call

    /// Leave/end the current Webex meeting by pressing the leave button via Accessibility API.
    func leaveCall() {
        guard let pid = findWebexPID() else { return }

        if let button = findLeaveButtonInWindows(pid: pid) {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success { return }
        }

        // Fallback: Cmd+L keystroke
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Config.leaveShortcutKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Config.leaveShortcutKeyCode, keyDown: false)
        keyDown?.flags = Config.leaveShortcutModifiers
        keyUp?.flags = Config.leaveShortcutModifiers
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)
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
            currentState = newState
            delegate?.webexMonitor(self, didDetectState: newState)
        }

        // Detect video state during active meetings
        let newVideoState: WebexVideoState
        switch newState {
        case .muted, .unmuted:
            newVideoState = detectVideoState()
        default:
            newVideoState = .unknown
        }
        if newVideoState != currentVideoState {
            currentVideoState = newVideoState
            delegate?.webexMonitor(self, didDetectVideoState: newVideoState)
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
        let text = combinedText(of: button)
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
            let text = combinedText(of: element)
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
            let text = combinedText(of: element)
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

    // MARK: - Video State Detection

    private func detectVideoState() -> WebexVideoState {
        guard let pid = findWebexPID() else { return .unknown }

        // Fast path: read cached video button
        if let button = cachedVideoButton {
            if let state = readVideoState(from: button) {
                videoCacheFailCount = 0
                return state
            }
            videoCacheFailCount += 1
            if videoCacheFailCount > 2 {
                cachedVideoButton = nil
            }
        }

        // Slow path: find the video button
        if let button = findVideoButtonInWindows(pid: pid) {
            cachedVideoButton = button
            videoCacheFailCount = 0
            if let state = readVideoState(from: button) {
                return state
            }
        }

        return .unknown
    }

    /// Read video state from a button element
    private func readVideoState(from button: AXUIElement) -> WebexVideoState? {
        let text = combinedText(of: button)
        guard text.contains("video") else { return nil }

        if text.contains("start") {
            return .videoOff
        } else if text.contains("stop") {
            return .videoOn
        }
        return nil
    }

    private func findVideoButtonInWindows(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            if let button = findVideoButtonElement(window, depth: 0) {
                return button
            }
        }
        return nil
    }

    private func findVideoButtonElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }

        let role = axRole(of: element)

        if role == kAXButtonRole as String {
            let text = combinedText(of: element)
            if text.contains("video") && (text.contains("start") || text.contains("stop")) {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let button = findVideoButtonElement(child, depth: depth + 1) {
                return button
            }
        }
        return nil
    }

    // MARK: - Leave Button Discovery

    private func findLeaveButtonInWindows(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            if let button = findLeaveButtonElement(window, depth: 0) {
                return button
            }
        }
        return nil
    }

    private func findLeaveButtonElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }

        let role = axRole(of: element)

        if role == kAXButtonRole as String {
            let text = combinedText(of: element)
            if text.contains("leave") || text.contains("end meeting") {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let button = findLeaveButtonElement(child, depth: depth + 1) {
                return button
            }
        }
        return nil
    }

    // MARK: - Cache Management

    private func invalidateCache() {
        cachedMuteButton = nil
        cachedVideoButton = nil
        cachedWebexPID = nil
        cacheFailCount = 0
        videoCacheFailCount = 0
    }

    // MARK: - Accessibility Helpers

    /// Combined lowercase text of an element's description and title
    private func combinedText(of element: AXUIElement) -> String {
        let desc = axDescription(of: element)
        let title = axTitle(of: element)
        return [desc, title].compactMap { $0 }.joined(separator: " ").lowercased()
    }

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
