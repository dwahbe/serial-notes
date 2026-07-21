// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SerialNotes",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Vendored with a patched resource-bundle accessor (production Settings
        // crash — see Vendor/KeyboardShortcuts/VENDORED.md).
        .package(path: "Vendor/KeyboardShortcuts"),
    ],
    targets: [
        .target(
            name: "SystemAudioTap",
            path: "Sources/SystemAudioTap",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "SerialNotes",
            dependencies: [
                "SystemAudioTap",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/SerialNotes",
            exclude: ["Info.plist", "SerialNotes.entitlements", "AppIcon.icns"]
        ),
        .testTarget(
            name: "AudioPipelineTests",
            dependencies: [
                "SerialNotes",
                "SystemAudioTap",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Tests/AudioPipelineTests",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
