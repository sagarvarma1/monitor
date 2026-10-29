// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SwitchboardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Switchboard",
            dependencies: ["SwitchboardCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "SwitchboardCoreTests",
            dependencies: ["SwitchboardCore"]
        ),
    ]
)
