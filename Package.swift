// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "JevClient",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "JevClient",
            targets: ["JevClient"]
        ),
    ],
    targets: [
        .target(
            name: "JevClient",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "JevClientTests",
            dependencies: ["JevClient"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
