import Foundation
import CoreGraphics

enum Config {
    // MARK: - Anker PowerConf S3 HID identifiers
    // Update these after running the DiscoverAnker tool with the device plugged in

    /// Anker vendor ID
    static let ankerVendorID: Int = 0x291A

    /// Anker PowerConf S3 product ID
    static let ankerProductID: Int = 0x3302

    /// Primary HID Usage Page (Consumer — device exposes both Consumer 0x0C and Telephony 0x0B)
    static let primaryUsagePage: Int = 0x0C

    // MARK: - HID Report Structure
    // Determined from device HID report descriptor via DiscoverAnker + ioreg.
    //
    // Input Report ID 1 (2 bytes): Consumer controls (Vol Up/Down, Mute 0xE2, Play/Pause, etc.)
    // Input Report ID 2 (2 bytes): Telephony (Hook Switch, Flash, Redial, Phone Mute 0x2F)
    // Output Report ID 3 (1 byte): LED Do Not Disturb (UP 0x08, Usage 0x18)
    // Output Report ID 4 (1 byte): LED Mute (UP 0x08, Usage 0x09)
    // Output Report ID 5 (1 byte): LED On-Line (UP 0x08, Usage 0x20)
    // Output Report ID 6 (1 byte): LED various status indicators

    /// Report ID for the mute LED output report (sent TO the device)
    /// LED Usage Page 0x08, Usage 0x09 (Mute)
    static let muteLEDReportID: Int = 4

    /// Byte index within the output report where mute LED bit lives
    static let muteLEDByteIndex: Int = 0

    /// Bit mask for the mute LED within the byte
    static let muteLEDBitMask: UInt8 = 0x01

    /// Total size of the output report in bytes (excluding report ID byte)
    static let outputReportSize: Int = 1

    /// Report ID for the mute button input report (received FROM the device)
    /// Telephony Usage Page 0x0B, Usage 0x2F (Phone Mute) — bit 3 of Report ID 2
    static let muteButtonReportID: Int = 2

    /// Byte index within the input report where mute button bit lives
    /// Report ID 2 data is 2 bytes: [byte0, byte1]. Phone Mute is in byte1.
    static let muteButtonByteIndex: Int = 1

    /// Bit mask for the mute button within the byte (bit 3 = Phone Mute 0x2F)
    static let muteButtonBitMask: UInt8 = 0x08

    // MARK: - Ring LED
    /// HID Usage 0x18 (Ring) — blinking green LED for incoming calls
    static let ringLEDUsage: Int = 0x18

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

    // MARK: - Accessibility Menu Path

    /// Menu bar path to the mute menu item in Webex
    /// Navigate: Menu Bar > Meetings & Calls (or Meeting) > Audio & Video > Mute / Unmute
    static let webexMenuBarItems = [
        ["Meeting", "Meetings & Calls"],           // Menu title (try both)
        ["Audio & Video"],                          // Submenu
    ]
    /// The mute menu item title patterns to look for
    static let muteMenuItemPatterns = ["Mute", "Unmute"]
}
