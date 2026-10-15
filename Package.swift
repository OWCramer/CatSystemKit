// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "CatSystemKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "CatSystemKit", targets: ["CatSystemKit"]),
        .executable(name: "cs2-cli", targets: ["cs2-cli"]),
    ],
    targets: [
        // Optimised even in Debug: Blowfish and the HG-3 decoder run over whole pictures.
        .target(name: "CatSystemKit", swiftSettings: [.unsafeFlags(["-O"])]),
        // Developer tool: lists archives, dumps scripts and exports images from the Mac.
        .executableTarget(name: "cs2-cli", dependencies: ["CatSystemKit"]),
        .testTarget(name: "CatSystemKitTests", dependencies: ["CatSystemKit"]),
    ]
)
