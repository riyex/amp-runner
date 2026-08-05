// swift-tools-version:5.9
import PackageDescription

// AmpRunnerCore is intentionally Foundation-only (no AppKit / SwiftUI /
// UserNotifications / ServiceManagement) so the whole business-logic layer can be
// built and unit-tested on Linux as well as macOS.
let package = Package(
    name: "AmpRunnerCore",
    products: [
        .library(name: "AmpRunnerCore", targets: ["AmpRunnerCore"]),
        .library(name: "AmpRunnerMonitorSupport", targets: ["AmpRunnerMonitorSupport"])
    ],
    targets: [
        .target(name: "AmpRunnerCore"),
        .target(name: "AmpRunnerMonitorSupport"),
        .executableTarget(
            name: "AmpRunnerMonitor",
            dependencies: ["AmpRunnerMonitorSupport"]
        ),
        .testTarget(
            name: "AmpRunnerCoreTests",
            dependencies: [
                "AmpRunnerCore",
                "AmpRunnerMonitorSupport"
            ]
        )
    ]
)
