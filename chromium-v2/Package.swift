// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChromiumFingerprintBrowser",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ChromiumFingerprintBrowser", targets: ["ChromiumFingerprintBrowser"]),
    ],
    targets: [
        .executableTarget(
            name: "ChromiumFingerprintBrowser",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
