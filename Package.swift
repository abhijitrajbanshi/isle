// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Isle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Isle", targets: ["Isle"]),
    ],
    targets: [
        // Platform-independent island logic: presentation state machine,
        // layout and gesture interpretation. Fully unit tested.
        .target(name: "IsleKit"),

        // The app: AppKit shell, system integrations and SwiftUI views.
        .executableTarget(
            name: "Isle",
            dependencies: ["IsleKit"],
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

        .testTarget(name: "IsleKitTests", dependencies: ["IsleKit"]),
        .testTarget(name: "IsleTests", dependencies: ["Isle", "IsleKit"]),
    ]
)
