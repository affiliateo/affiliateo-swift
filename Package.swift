// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Affiliateo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Affiliateo",
            targets: ["Affiliateo"]
        ),
    ],
    targets: [
        .target(
            name: "Affiliateo",
            path: "Sources/Affiliateo"
        ),
    ]
)
