# WebexMuteSync

A macOS menu bar app that syncs Webex mute state with the Anker PowerConf S3 speakerphone's mute LED over USB.

## Features

- **Bidirectional mute sync** — Mute/unmute in Webex and the Anker's red LED follows. Press the Anker's mute button and Webex toggles to match.
- **Menu bar icon** — Colored icon reflects current state (red = muted, green = unmuted, gray = idle/no Webex, orange = device issue). Adapts to dark and light mode.
- **Device info dropdown** — Shows device name, connection type (USB/Bluetooth), and sync status.
- **Bluetooth detection** — Detects when the Anker is connected via Bluetooth and prompts for USB (LED control requires USB).
- **Incoming call alert** — Detects incoming Webex calls, flashes the Anker's green ring LED, and animates a phone icon in the menu bar.
- **Fast polling** — Cached Accessibility API references for sub-second mute state detection during active meetings.

## Requirements

- macOS 13+
- Anker PowerConf S3 connected via USB
- Webex desktop app (classic or newer)
- Accessibility permission (prompted on first launch)

## Build

```bash
cd WebexMuteSync
swift build
```

## Run

```bash
.build/debug/WebexMuteSync
```

The app runs as a menu bar accessory (no dock icon). Click the mic icon to see status, or quit from the dropdown menu.

## How It Works

WebexMuteSync uses three macOS APIs:

- **IOKit HID** — Communicates with the Anker over USB. Sets individual HID elements (Off-Hook, Mute, Ring) to control LEDs, and reads input reports to detect button presses.
- **Accessibility API** — Reads Webex's UI tree to find the mute button, detect mute/unmute state, and detect incoming call windows (Answer/Decline buttons). Caches button references to avoid expensive tree walks on every poll.
- **IOBluetooth** — Detects if the Anker is paired and connected via Bluetooth (where LED control is unavailable).

### Anker PowerConf S3 HID Notes

The device exposes Consumer (0x0C) and Telephony (0x0B) usage pages on a single HID interface. LED control requires setting individual output elements via `IOHIDDeviceSetValue` — raw `IOHIDDeviceSetReport` succeeds silently but has no effect.

| Function | Usage Page | Usage | Notes |
|----------|-----------|-------|-------|
| Off-Hook | 0x08 | 0x17 | Must be ON before Mute/Ring respond |
| Mute LED | 0x08 | 0x09 | Red LED on/off |
| Ring LED | 0x08 | 0x18 | Blinking green |
| Mute Button | 0x0B | 0x2F | Input Report ID 2, byte 1, bit 3 |

Over Bluetooth, the device uses HFP/A2DP/AVRCP only — no HID interface is exposed, so button events and LED control are unavailable.

## CLI Tools

Development/diagnostic tools in `Tools/`:

- **DiscoverAnker** — Enumerates HID devices and dumps element descriptors for the Anker.
- **TestLED** — Toggles the mute LED on/off for testing.
- **TestAllLEDs** — Cycles through all output elements to identify LED behaviors.
- **TestWebexState** — Polls and prints Webex mute state via Accessibility API.
- **SniffBTEvents** — Monitors system events to check if Bluetooth button presses are detectable (they aren't).

## License

MIT
