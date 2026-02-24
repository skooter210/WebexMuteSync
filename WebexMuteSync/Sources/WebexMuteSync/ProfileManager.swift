import Foundation

/// Manages device profiles: built-in lookups and user-saved profiles on disk.
final class ProfileManager {
    static let shared = ProfileManager()

    private let profilesDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        profilesDirectory = appSupport.appendingPathComponent("WebexMuteSync/profiles", isDirectory: true)
    }

    // MARK: - Lookup

    /// Find a profile for the given VID/PID. Checks built-in profiles first, then user profiles.
    /// Returns `nil` if no specific match found (caller should use `.generic`).
    func profileFor(vendorID: Int, productID: Int) -> DeviceProfile? {
        // Built-in profiles
        if let builtIn = DeviceProfile.builtInProfiles.first(where: {
            $0.vendorID == vendorID && $0.productID == productID
        }) {
            return builtIn
        }

        // User-saved profiles
        let filename = profileFilename(vendorID: vendorID, productID: productID)
        let fileURL = profilesDirectory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
            return profile
        } catch {
            print("[ProfileManager] Failed to load profile \(filename): \(error)")
            return nil
        }
    }

    // MARK: - Save / Delete

    func saveProfile(_ profile: DeviceProfile) throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)

        let filename = profileFilename(vendorID: profile.vendorID, productID: profile.productID)
        let fileURL = profilesDirectory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: fileURL, options: .atomic)

        print("[ProfileManager] Saved profile: \(filename)")
    }

    func deleteProfile(vendorID: Int, productID: Int) throws {
        let filename = profileFilename(vendorID: vendorID, productID: productID)
        let fileURL = profilesDirectory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
        print("[ProfileManager] Deleted profile: \(filename)")
    }

    /// List all user-saved profiles
    func userProfiles() -> [DeviceProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: profilesDirectory,
                                                                        includingPropertiesForKeys: nil) else {
            return []
        }

        return files.compactMap { url -> DeviceProfile? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DeviceProfile.self, from: data)
        }
    }

    // MARK: - Helpers

    private func profileFilename(vendorID: Int, productID: Int) -> String {
        String(format: "%04X-%04X.json", vendorID, productID)
    }
}
