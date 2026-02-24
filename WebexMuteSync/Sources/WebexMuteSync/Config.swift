import Foundation
import CoreGraphics

enum Config {
    // MARK: - Polling Intervals

    /// Polling interval when Webex is in an active meeting (seconds)
    static let activeMeetingPollInterval: TimeInterval = 0.3

    /// Polling interval when Webex is running but not in a meeting (seconds)
    static let idlePollInterval: TimeInterval = 2.0

    /// Polling interval when Webex is not running (seconds)
    static let noWebexPollInterval: TimeInterval = 5.0

    // MARK: - Sync

    /// Cooldown period after a device button press to prevent feedback loops (seconds)
    static let buttonPressCooldown: TimeInterval = 1.0

    /// Debounce interval for HID button presses (seconds)
    /// Device sends two complete down/up cycles per physical press (bounce).
    /// 400ms eats the bounce while still allowing deliberate rapid presses.
    static let buttonDebounceInterval: TimeInterval = 0.4

    // MARK: - Webex

    /// Webex bundle identifier
    static let webexBundleID = "com.cisco.webexmeetingsapp"

    /// Alternative Webex bundle identifier (newer versions)
    static let webexBundleIDAlt = "Cisco-Systems.Spark"

    /// Keyboard shortcut to toggle mute in Webex: Cmd+Shift+M
    static let muteShortcutKeyCode: CGKeyCode = 0x2E  // 'M' key
    static let muteShortcutModifiers: CGEventFlags = [.maskCommand, .maskShift]

    /// Keyboard shortcut to toggle video in Webex: Cmd+Shift+V
    static let videoShortcutKeyCode: CGKeyCode = 0x09  // 'V' key
    static let videoShortcutModifiers: CGEventFlags = [.maskCommand, .maskShift]

    // MARK: - Accessibility Menu Path

    /// Menu bar path to the mute menu item in Webex
    /// Navigate: Menu Bar > Meetings & Calls (or Meeting) > Audio & Video > Mute / Unmute
    static let webexMenuBarItems = [
        ["Meeting", "Meetings & Calls"],           // Menu title (try both)
        ["Audio & Video"],                          // Submenu
    ]
    /// The mute menu item title patterns to look for
    static let muteMenuItemPatterns = ["Mute", "Unmute"]

    // MARK: - GitHub

    /// GitHub repo for submitting device profiles as issues
    static let githubRepoSlug = "cmoss1/WebexMuteSync"
}
