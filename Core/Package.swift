// swift-tools-version: 6.2
import PackageDescription

let coreSettings: [SwiftSetting] = [
    .defaultIsolation(nil),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "VoiceToTextCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VoiceToTextCore", targets: ["VoiceToTextCore"]),
    ],
    targets: [
        .target(
            name: "VoiceToTextCore",
            swiftSettings: coreSettings
        ),
        .testTarget(
            name: "VoiceToTextCoreTests",
            dependencies: ["VoiceToTextCore"],
            swiftSettings: coreSettings
        ),
        .testTarget(
            name: "VoiceToTextIntegrationTests",
            dependencies: ["VoiceToTextCore"],
            // Fixtures are loaded by #filePath-relative URL, not bundled as resources (N1, R14).
            exclude: ["Fixtures"],
            swiftSettings: coreSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
