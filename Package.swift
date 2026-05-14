// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MultiProfileFingerprintBrowser",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "MultiProfileFingerprintBrowser", targets: ["MultiProfileFingerprintBrowser"]),
    ],
    targets: [
        .executableTarget(
            name: "MultiProfileFingerprintBrowser",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
