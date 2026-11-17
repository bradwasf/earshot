// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Earshot", targets: ["Earshot"]),
        .executable(name: "earshot-cli", targets: ["earshot-cli"]),
    ],
    dependencies: [
        // On-device Core ML speech stack: Parakeet ASR, Silero VAD, Sortformer diarization, LocalVQE echo cancellation.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(
            name: "EarshotCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/EarshotCore"
        ),
        .testTarget(
            name: "EarshotCoreTests",
            dependencies: ["EarshotCore"],
            path: "Tests/EarshotCoreTests"
        ),
        .executableTarget(
            name: "Earshot",
            dependencies: ["EarshotCore"],
            path: "Sources/Earshot"
        ),
        .executableTarget(
            name: "earshot-cli",
            dependencies: ["EarshotCore"],
            path: "Sources/earshot-cli",
            linkerSettings: [
                // Embed an Info.plist so the CLI can show the microphone / system-audio prompts.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/cli-Info.plist",
                ])
            ]
        ),
    ]
)
