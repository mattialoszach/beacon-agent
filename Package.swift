// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Beacon", targets: ["Beacon"])
    ],
    targets: [
        .executableTarget(
            name: "Beacon",
            path: "Beacon",
            exclude: [
                "Resources/AppIcon.icns",
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources/Images")
            ]
        ),
        .testTarget(
            name: "BeaconTests",
            dependencies: ["Beacon"],
            path: "Tests"
        )
    ]
)
