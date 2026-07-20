// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingVault",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MeetingVault", targets: ["MeetingVault"]),
        .executable(name: "MeetingVaultAppShortcutsCatalogSmoke", targets: ["MeetingVaultAppShortcutsCatalogSmoke"]),
        .executable(name: "MeetingVaultCaptureProviderSmoke", targets: ["MeetingVaultCaptureProviderSmoke"]),
        .executable(name: "MeetingVaultFoundationModelsSmoke", targets: ["MeetingVaultFoundationModelsSmoke"]),
        .executable(name: "MeetingVaultLogRedactionSmoke", targets: ["MeetingVaultLogRedactionSmoke"]),
        .executable(name: "MeetingVaultLongRecordingStressSmoke", targets: ["MeetingVaultLongRecordingStressSmoke"]),
        .executable(name: "MeetingVaultLocalModelLifecycleSmoke", targets: ["MeetingVaultLocalModelLifecycleSmoke"]),
        .executable(name: "MeetingVaultLocalTranscriptionFixtureSmoke", targets: ["MeetingVaultLocalTranscriptionFixtureSmoke"]),
        .executable(name: "MeetingVaultConfidenceReviewSmoke", targets: ["MeetingVaultConfidenceReviewSmoke"]),
        .executable(name: "MeetingVaultLocalModelSelfCheck", targets: ["MeetingVaultLocalModelSelfCheck"]),
        .executable(name: "MeetingVaultProviderReadinessDoctor", targets: ["MeetingVaultProviderReadinessDoctor"]),
        .executable(name: "MeetingVaultReleaseBlockerDoctor", targets: ["MeetingVaultReleaseBlockerDoctor"]),
        .library(name: "MeetingVaultCore", targets: ["MeetingVaultCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "MeetingVaultCore",
            dependencies: [
                "CSQLite",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MeetingVault",
            dependencies: ["MeetingVaultCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MeetingVaultAppShortcutsCatalogSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultCaptureProviderSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultFoundationModelsSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultLogRedactionSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultLongRecordingStressSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultLocalModelLifecycleSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultLocalTranscriptionFixtureSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultConfidenceReviewSmoke",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultLocalModelSelfCheck",
            dependencies: ["MeetingVaultCore"]
        ),
        .executableTarget(
            name: "MeetingVaultProviderReadinessDoctor"
        ),
        .executableTarget(
            name: "MeetingVaultReleaseBlockerDoctor"
        ),
        .testTarget(
            name: "MeetingVaultCoreTests",
            dependencies: ["MeetingVaultCore", "MeetingVaultCaptureProviderSmoke"]
        ),
        .testTarget(
            name: "MeetingVaultAppTests",
            dependencies: ["MeetingVault", "MeetingVaultCore"]
        )
    ]
)
