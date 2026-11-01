// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Isle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Isle", targets: ["Isle"]),
        .executable(name: "isle-cli", targets: ["IsleCLI"]),
    ],
    dependencies: [
        // Auto-updates: EdDSA-signed appcast, the standard macOS updater.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Platform-independent island logic: presentation state machine,
        // layout and gesture interpretation. Fully unit tested.
        .target(name: "IsleKit"),

        // The app: AppKit shell, system integrations and SwiftUI views.
        .executableTarget(
            name: "Isle",
            dependencies: ["IsleKit", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        ),

        // `isle`: the command-line side of the activity API, bundled in the
        // app. Claude Code hooks and scripts use it to report to the island.
        .executableTarget(name: "IsleCLI"),

        .testTarget(name: "IsleKitTests", dependencies: ["IsleKit"]),
        .testTarget(name: "IsleTests", dependencies: ["Isle", "IsleKit"]),
    ]
)
