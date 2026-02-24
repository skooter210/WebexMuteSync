import Foundation

/// Describes a speakerphone's HID element configuration for LED control and mute button input.
struct DeviceProfile: Codable, Equatable {
    let name: String
    let vendorID: Int
    let productID: Int

    // Output element usages (Telephony page 0x0B)
    let offHookUsage: Int?      // e.g. 0x17 — required by most devices before Mute LED responds
    let muteLEDUsage: Int        // e.g. 0x09
    let ringLEDUsage: Int?       // e.g. 0x18

    // Input element for mute button
    let muteButtonUsagePage: Int // e.g. 0x0B (Telephony)
    let muteButtonUsage: Int     // e.g. 0x2F (Phone Mute)

    /// Whether Off-Hook must be set before Mute LED responds
    let requiresOffHook: Bool

    /// `nil` = auto-detect via IOHIDElementIsRelative at runtime
    let isRelative: Bool?

    /// Built-in profiles cannot be deleted by the user
    let isBuiltIn: Bool

    let createdAt: Date

    // MARK: - Built-in Profiles

    static let ankerS3 = DeviceProfile(
        name: "Anker PowerConf S3",
        vendorID: 0x291A,
        productID: 0x3302,
        offHookUsage: 0x17,
        muteLEDUsage: 0x09,
        ringLEDUsage: 0x18,
        muteButtonUsagePage: 0x0B,
        muteButtonUsage: 0x2F,
        requiresOffHook: true,
        isRelative: false,
        isBuiltIn: true,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    static let ankerS500 = DeviceProfile(
        name: "Anker PowerConf S500",
        vendorID: 0x291A,
        productID: 0x3305,
        offHookUsage: 0x17,
        muteLEDUsage: 0x09,
        ringLEDUsage: 0x18,
        muteButtonUsagePage: 0x0B,
        muteButtonUsage: 0x2F,
        requiresOffHook: true,
        isRelative: true,
        isBuiltIn: true,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    /// Generic fallback for unknown telephony speakerphones — uses standard HID telephony usages.
    static let generic = DeviceProfile(
        name: "Generic Speakerphone",
        vendorID: 0,
        productID: 0,
        offHookUsage: 0x17,
        muteLEDUsage: 0x09,
        ringLEDUsage: 0x18,
        muteButtonUsagePage: 0x0B,
        muteButtonUsage: 0x2F,
        requiresOffHook: true,
        isRelative: nil,
        isBuiltIn: false,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    // MARK: - All built-in profiles

    static let builtInProfiles: [DeviceProfile] = [.ankerS3, .ankerS500]

    /// Create a mutable copy with updated element assignments
    func withUpdatedUsages(
        offHookUsage: Int?? = nil,
        muteLEDUsage: Int? = nil,
        ringLEDUsage: Int?? = nil,
        muteButtonUsagePage: Int? = nil,
        muteButtonUsage: Int? = nil,
        requiresOffHook: Bool? = nil,
        isRelative: Bool?? = nil
    ) -> DeviceProfile {
        DeviceProfile(
            name: self.name,
            vendorID: self.vendorID,
            productID: self.productID,
            offHookUsage: offHookUsage ?? self.offHookUsage,
            muteLEDUsage: muteLEDUsage ?? self.muteLEDUsage,
            ringLEDUsage: ringLEDUsage ?? self.ringLEDUsage,
            muteButtonUsagePage: muteButtonUsagePage ?? self.muteButtonUsagePage,
            muteButtonUsage: muteButtonUsage ?? self.muteButtonUsage,
            requiresOffHook: requiresOffHook ?? self.requiresOffHook,
            isRelative: isRelative ?? self.isRelative,
            isBuiltIn: false,
            createdAt: Date()
        )
    }
}
