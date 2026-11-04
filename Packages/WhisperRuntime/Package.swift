// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperRuntime",
    platforms: [.macOS("13.3")],
    products: [
        .library(name: "WhisperRuntime", targets: ["WhisperRuntime"]),
        .executable(name: "whisper-benchmark", targets: ["WhisperBenchmark"])
    ],
    targets: [
        .target(name: "WhisperRuntime", dependencies: ["WhisperFramework"]),
        .executableTarget(name: "WhisperBenchmark", dependencies: ["WhisperRuntime"]),
        .testTarget(name: "WhisperRuntimeTests", dependencies: ["WhisperRuntime"], resources: [.process("Fixtures")]),
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        )
    ]
)
