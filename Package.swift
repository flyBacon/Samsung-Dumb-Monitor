// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "SamsungDumbMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "S9InputControl", targets: ["S9InputControl"]),
        .executable(name: "DumbMonitor", targets: ["DumbMonitor"]),
        .executable(name: "s9-input", targets: ["S9InputCLI"]),
    ],
    targets: [
        .target(name: "S9InputControl"),
        .executableTarget(name: "DumbMonitor", dependencies: ["S9InputControl"]),
        .executableTarget(name: "S9InputCLI", dependencies: ["S9InputControl"]),
        .testTarget(name: "DumbMonitorTests", dependencies: ["DumbMonitor", "S9InputControl"]),
    ]
)
