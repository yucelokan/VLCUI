// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VLCUI",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "VLCUI",
            targets: ["VLCUI"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/yucelokan/vlckit-spm.git", branch: "main")
    ],
    targets: [
        .target(
            name: "VLCUI",
            dependencies: [
                .product(name: "VLCKitSPM", package: "vlckit-spm")
            ]
        ),
    ]
)
