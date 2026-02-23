// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebexMuteSync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WebexMuteSync",
            path: "Sources/WebexMuteSync",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOBluetooth"),
            ]
        ),
        .executableTarget(
            name: "DiscoverAnker",
            path: "Tools/DiscoverAnker",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "TestLED",
            path: "Tools/TestLED",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "TestWebexState",
            path: "Tools/TestWebexState",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "TestAllLEDs",
            path: "Tools/TestAllLEDs",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "SniffBTEvents",
            path: "Tools/SniffBTEvents",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
