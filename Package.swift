// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VLCUI",
    platforms: [
        .iOS(.v14),
        .tvOS(.v14),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "VLCUI",
            targets: ["VLCUI"]
        ),
    ],
    dependencies: [
        // VLCKit 4.0 SPM package - LOCAL PATH FOR DEVELOPMENT
        .package(path: "../vlckit-spm-4.0")
    ],
    targets: [
        .target(
            name: "VLCUI",
            dependencies: [
                .product(name: "VLCKitSPM", package: "vlckit-spm-4.0")
            ]
        ),
    ]
)
