// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wispr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // Relaxed to <1.2.0: WhisperKit pins swift-transformers 1.1.x, and this
        // dependency only exists so the Tokenizers module is importable.
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
    ],
    targets: [
        .target(
            name: "WisprCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/WisprCore"
        ),
        .executableTarget(
            name: "Wispr",
            dependencies: ["WisprCore"],
            path: "Sources/WisprApp"
        ),
        .testTarget(
            name: "WisprCoreTests",
            dependencies: [
                "WisprCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Tests/WisprCoreTests"
        ),
    ]
)
