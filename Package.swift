// swift-tools-version: 5.9
//
// SDK version: 4.4.0
// Swift Package Manager resolves the actual version from git tags, not
// from this file. The marker above documents the current source state
// so casual readers don't have to cross-reference the latest tag.
// 4.4.0: version alignment — every Affiliateo SDK (web, React Native,
// Swift, Kotlin, Flutter) now ships the same version number. Identical
// source to 3.2.0.
// 3.2.0: Apple Search Ads attribution — the SDK grabs the AdServices
// token once per install (iOS 14.3+, no ATT prompt) and hands it to the
// backend, which redeems it with Apple for campaign/ad-group/keyword
// attribution. Additive, no API changes.

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
