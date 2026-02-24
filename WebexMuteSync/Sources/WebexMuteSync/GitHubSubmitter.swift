import Foundation

/// Submits a DeviceProfile as a GitHub issue using the `gh` CLI tool.
enum GitHubSubmitter {

    /// Whether the `gh` CLI is available on the system.
    static var isAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "gh"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Submit a device profile as a GitHub issue.
    ///
    /// - Parameters:
    ///   - profile: The device profile to submit.
    ///   - completion: Called with the issue URL on success, or an error.
    static func submitProfile(_ profile: DeviceProfile, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try runSubmission(profile)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func runSubmission(_ profile: DeviceProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(profile)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let title = "Device Profile: \(profile.name) (\(String(format: "0x%04X:0x%04X", profile.vendorID, profile.productID)))"

        let body = """
        ## Device Profile Submission

        **Product Name:** \(profile.name)
        **Vendor ID:** \(String(format: "0x%04X", profile.vendorID))
        **Product ID:** \(String(format: "0x%04X", profile.productID))
        **macOS Version:** \(macOSVersion)
        **Requires Off-Hook:** \(profile.requiresOffHook)
        **Is Relative:** \(profile.isRelative.map(String.init(describing:)) ?? "auto-detect")

        ### Profile JSON

        ```json
        \(jsonString)
        ```

        ---
        *Submitted automatically by WebexMuteSync device configuration panel.*
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gh", "issue", "create",
            "--repo", Config.githubRepoSlug,
            "--title", title,
            "--body", body,
            "--label", "device-profile",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw SubmissionError.ghFailed(output)
        }

        return output
    }

    enum SubmissionError: LocalizedError {
        case ghFailed(String)

        var errorDescription: String? {
            switch self {
            case .ghFailed(let output):
                return "GitHub CLI failed: \(output)\n\nMake sure 'gh' is installed and authenticated (run 'gh auth login')."
            }
        }
    }
}
