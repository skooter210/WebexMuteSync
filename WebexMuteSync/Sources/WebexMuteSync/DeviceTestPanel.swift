import AppKit
import IOKit.hid

/// Floating utility panel for testing and configuring an unknown speakerphone's HID elements.
final class DeviceTestPanel: NSPanel {
    private let hidDevice: HIDDevice

    /// Called when user clicks "Save Profile" with the configured profile
    var onSaveProfile: ((DeviceProfile) -> Void)?

    /// Called when user clicks "Submit to GitHub" with the configured profile
    var onSubmitToGitHub: ((DeviceProfile) -> Void)?

    /// Called when the panel closes (for cleanup)
    var onClose: (() -> Void)?

    // Element assignments (user can reassign via popups)
    private var offHookElement: IOHIDElement?
    private var muteLEDElement: IOHIDElement?
    private var ringLEDElement: IOHIDElement?

    // Mute button detection
    private var detectedMuteUsagePage: UInt32?
    private var detectedMuteUsage: UInt32?
    private var detectedMuteIsRelative: Bool?

    // UI elements
    private var muteIndicator: NSView!
    private var muteInfoLabel: NSTextField!
    private var elementRows: [(info: HIDOutputElementInfo, popup: NSPopUpButton)] = []

    // Toggle state tracking for element test buttons
    private var activeToggleTimers: [UInt32: Timer] = [:]

    init(hidDevice: HIDDevice) {
        self.hidDevice = hidDevice

        let contentRect = NSRect(x: 0, y: 0, width: 500, height: 620)
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered,
                   defer: false)

        self.title = "Device Configuration"
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.center()

        setupUI()
        loadCurrentAssignments()
        startInputMonitoring()
    }

    // MARK: - UI Setup

    private func setupUI() {
        let scrollView = NSScrollView(frame: contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 1. Device Info Header
        addDeviceInfoSection(to: stack)

        // 2. Separator
        addSeparator(to: stack)

        // 3. Quick LED Test
        addQuickLEDSection(to: stack)

        // 4. Separator
        addSeparator(to: stack)

        // 5. All Output Elements
        addOutputElementsSection(to: stack)

        // 6. Separator
        addSeparator(to: stack)

        // 7. Mute Button Test
        addMuteButtonSection(to: stack)

        // 8. Separator
        addSeparator(to: stack)

        // 9. Action Buttons
        addActionButtons(to: stack)

        // Set up scroll view document
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        contentView?.addSubview(scrollView)
    }

    private func addDeviceInfoSection(to stack: NSStackView) {
        let header = makeLabel("Device Information", bold: true, size: 14)
        stack.addArrangedSubview(header)

        let name = hidDevice.productName ?? "Unknown Device"
        let profile = hidDevice.activeProfile
        let vid = profile?.vendorID ?? 0
        let pid = profile?.productID ?? 0

        let nameLabel = makeLabel("Name: \(name)")
        stack.addArrangedSubview(nameLabel)

        let idLabel = makeLabel(String(format: "VID: 0x%04X  PID: 0x%04X", vid, pid))
        stack.addArrangedSubview(idLabel)

        let usbLabel = makeLabel("Transport: \(hidDevice.isUSB ? "USB" : "Bluetooth")")
        stack.addArrangedSubview(usbLabel)

        if hidDevice.isKnownProfile {
            let knownLabel = makeLabel("Profile: \(profile?.name ?? "Built-in") (known)")
            knownLabel.textColor = .systemGreen
            stack.addArrangedSubview(knownLabel)
        } else {
            let unknownLabel = makeLabel("Profile: Generic (unknown device — configure below)")
            unknownLabel.textColor = .systemOrange
            stack.addArrangedSubview(unknownLabel)
        }
    }

    private func addQuickLEDSection(to stack: NSStackView) {
        let header = makeLabel("Quick LED Test", bold: true, size: 13)
        stack.addArrangedSubview(header)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let offHookBtn = makeButton("Off-Hook") { [weak self] in self?.toggleQuickLED(usage: 0x17) }
        let muteBtn = makeButton("Mute LED") { [weak self] in self?.toggleQuickLED(usage: 0x09) }
        let ringBtn = makeButton("Ring LED") { [weak self] in self?.toggleQuickLED(usage: 0x18) }

        row.addArrangedSubview(offHookBtn)
        row.addArrangedSubview(muteBtn)
        row.addArrangedSubview(ringBtn)
        stack.addArrangedSubview(row)

        let hint = makeLabel("Each button sets element to 1 for 2 seconds, then back to 0.", size: 10)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
    }

    private func addOutputElementsSection(to stack: NSStackView) {
        let header = makeLabel("All Output Elements", bold: true, size: 13)
        stack.addArrangedSubview(header)

        let elements = hidDevice.allOutputElements()

        if elements.isEmpty {
            let noElements = makeLabel("No output elements found.")
            noElements.textColor = .secondaryLabelColor
            stack.addArrangedSubview(noElements)
            return
        }

        for info in elements {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let label = makeLabel(String(format: "Page:0x%02X  Usage:0x%02X  Report:%d",
                                         info.usagePage, info.usage, info.reportID), size: 11)
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

            let toggleBtn = makeButton("Toggle") { [weak self] in
                self?.toggleElement(info)
            }

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Ignore", "Off-Hook", "Mute LED", "Ring LED"])

            // Pre-select based on current profile assignment
            if let profile = hidDevice.activeProfile {
                if let offHook = profile.offHookUsage, info.usage == UInt32(offHook) {
                    popup.selectItem(at: 1)
                } else if info.usage == UInt32(profile.muteLEDUsage) {
                    popup.selectItem(at: 2)
                } else if let ring = profile.ringLEDUsage, info.usage == UInt32(ring) {
                    popup.selectItem(at: 3)
                }
            }

            popup.tag = Int(info.usage)

            row.addArrangedSubview(label)
            row.addArrangedSubview(toggleBtn)
            row.addArrangedSubview(popup)

            elementRows.append((info: info, popup: popup))
            stack.addArrangedSubview(row)
        }
    }

    private func addMuteButtonSection(to stack: NSStackView) {
        let header = makeLabel("Mute Button Test", bold: true, size: 13)
        stack.addArrangedSubview(header)

        let hint = makeLabel("Press the mute button on your device. The indicator will flash green.", size: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        // Indicator circle
        muteIndicator = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        muteIndicator.wantsLayer = true
        muteIndicator.layer?.cornerRadius = 10
        muteIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
        muteIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            muteIndicator.widthAnchor.constraint(equalToConstant: 20),
            muteIndicator.heightAnchor.constraint(equalToConstant: 20),
        ])

        muteInfoLabel = makeLabel("Waiting for input...")
        muteInfoLabel.textColor = .secondaryLabelColor

        row.addArrangedSubview(muteIndicator)
        row.addArrangedSubview(muteInfoLabel)
        stack.addArrangedSubview(row)
    }

    private func addActionButtons(to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let saveBtn = makeButton("Save Profile") { [weak self] in self?.saveProfile() }
        let submitBtn = makeButton("Submit to GitHub") { [weak self] in self?.submitToGitHub() }

        row.addArrangedSubview(saveBtn)
        row.addArrangedSubview(submitBtn)
        stack.addArrangedSubview(row)
    }

    // MARK: - Input Monitoring

    private func startInputMonitoring() {
        hidDevice.registerRawInputCallback { [weak self] event in
            DispatchQueue.main.async {
                self?.handleRawInput(event)
            }
        }
    }

    private func handleRawInput(_ event: HIDRawInputEvent) {
        // Flash indicator green
        muteIndicator?.layer?.backgroundColor = NSColor.systemGreen.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.muteIndicator?.layer?.backgroundColor = NSColor.systemGray.cgColor
        }

        let mode = event.isRelative ? "relative" : "absolute"
        muteInfoLabel?.stringValue = String(
            format: "Page:0x%02X  Usage:0x%02X  Value:%d  Mode:%@",
            event.usagePage, event.usage, event.intValue, mode
        )

        // Track the most recent non-zero input as the likely mute button
        if event.intValue != 0 {
            detectedMuteUsagePage = event.usagePage
            detectedMuteUsage = event.usage
            detectedMuteIsRelative = event.isRelative
        }
    }

    // MARK: - LED Toggle

    private func toggleQuickLED(usage: Int) {
        let elements = hidDevice.allOutputElements()
        guard let info = elements.first(where: { $0.usage == UInt32(usage) }) else {
            let alert = NSAlert()
            alert.messageText = "Element Not Found"
            alert.informativeText = String(format: "No output element with usage 0x%02X found on this device.", usage)
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        toggleElement(info)
    }

    private func toggleElement(_ info: HIDOutputElementInfo) {
        // Cancel any existing timer for this element
        activeToggleTimers[info.usage]?.invalidate()

        hidDevice.setElementValue(info.element, value: 1)

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hidDevice.setElementValue(info.element, value: 0)
            self?.activeToggleTimers.removeValue(forKey: info.usage)
        }
        activeToggleTimers[info.usage] = timer
    }

    // MARK: - Profile Actions

    private func loadCurrentAssignments() {
        guard let profile = hidDevice.activeProfile else { return }

        // Pre-populate detected mute button from profile
        detectedMuteUsagePage = UInt32(profile.muteButtonUsagePage)
        detectedMuteUsage = UInt32(profile.muteButtonUsage)
        detectedMuteIsRelative = profile.isRelative
    }

    private func buildProfileFromUI() -> DeviceProfile? {
        guard let baseProfile = hidDevice.activeProfile else { return nil }

        var offHook: Int?
        var muteLED: Int = baseProfile.muteLEDUsage
        var ringLED: Int?
        var needsOffHook = false

        for (info, popup) in elementRows {
            switch popup.indexOfSelectedItem {
            case 1: // Off-Hook
                offHook = Int(info.usage)
                needsOffHook = true
            case 2: // Mute LED
                muteLED = Int(info.usage)
            case 3: // Ring LED
                ringLED = Int(info.usage)
            default:
                break
            }
        }

        let mutePageInt = Int(detectedMuteUsagePage ?? UInt32(baseProfile.muteButtonUsagePage))
        let muteUsageInt = Int(detectedMuteUsage ?? UInt32(baseProfile.muteButtonUsage))

        return DeviceProfile(
            name: hidDevice.productName ?? "Unknown Speakerphone",
            vendorID: baseProfile.vendorID,
            productID: baseProfile.productID,
            offHookUsage: offHook,
            muteLEDUsage: muteLED,
            ringLEDUsage: ringLED,
            muteButtonUsagePage: mutePageInt,
            muteButtonUsage: muteUsageInt,
            requiresOffHook: needsOffHook,
            isRelative: detectedMuteIsRelative,
            isBuiltIn: false,
            createdAt: Date()
        )
    }

    private func saveProfile() {
        guard let profile = buildProfileFromUI() else { return }
        onSaveProfile?(profile)
    }

    private func submitToGitHub() {
        guard let profile = buildProfileFromUI() else { return }

        guard GitHubSubmitter.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "GitHub CLI Not Available"
            alert.informativeText = "The 'gh' CLI tool is required to submit profiles. Install it with: brew install gh"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        onSubmitToGitHub?(profile)
    }

    // MARK: - Lifecycle

    override func close() {
        // Clean up timers
        for timer in activeToggleTimers.values {
            timer.invalidate()
        }
        activeToggleTimers.removeAll()

        // Unregister raw input callback
        hidDevice.unregisterRawInputCallback()

        onClose?()
        super.close()
    }

    // MARK: - UI Helpers

    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold {
            label.font = NSFont.boldSystemFont(ofSize: size)
        } else {
            label.font = NSFont.systemFont(ofSize: size)
        }
        return label
    }

    private func makeButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        return button
    }

    private func addSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
}

// MARK: - ActionButton (closure-based NSButton)

private final class ActionButton: NSButton {
    private var actionHandler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.actionHandler = action
        self.target = self
        self.action = #selector(handleClick)
        self.bezelStyle = .rounded
    }

    @objc private func handleClick() {
        actionHandler?()
    }
}
