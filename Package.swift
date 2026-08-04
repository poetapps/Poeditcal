// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PoetAudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PoetAudio", targets: ["PoetAudio"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "372eb32a3b23342d11dca41ed75cd4d11d3f8955"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.2"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            from: "1.3.0"
        )
    ],
    targets: [
        .binaryTarget(
            name: "PoetDenoise",
            path: "Vendor/PoetDenoise.xcframework"
        ),
        .executableTarget(
            name: "PoetAudio",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "PoetDenoise"
            ],
            path: "Sources/PoetAudio",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "PoetAudioTests",
            dependencies: ["PoetAudio"],
            path: "Tests/PoetAudioTests"
        )
    ]
)
