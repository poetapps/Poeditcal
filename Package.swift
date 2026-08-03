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
                "PoetDenoise"
            ],
            path: "Sources/PoetAudio",
            resources: [
                .process("../../Resources")
            ],
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
