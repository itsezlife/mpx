// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "mpx_transfer",
    platforms: [
        // iOS 15 is the set's floor (spec, minimum versions).
        .iOS("15.0"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "mpx-transfer", targets: ["mpx_transfer"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "mpx_transfer",
            dependencies: [],
            resources: []
        )
    ]
)
