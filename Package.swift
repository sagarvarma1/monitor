// swift-tools-version: 5.9
import PackageDescription

// The shared core (and its tests). The Mac app, iPhone app and Live Activity are built from Switchboard.xcodeproj,
// generated from project.yml with `xcodegen`.
let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v13), .iOS("17.2")],
    products: [
        .library(name: "SwitchboardCore", targets: ["SwitchboardCore"]),
    ],
    targets: [
        .target(
            name: "SwitchboardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "SwitchboardCoreTests",
            dependencies: ["SwitchboardCore"]
        ),
    ]
)
