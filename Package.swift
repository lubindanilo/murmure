// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Murmure",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Murmure", targets: ["Murmure"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.18.4"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12728/llama-b12728-xcframework.zip",
            checksum: "2f983da2a18b9c705cbc0148cf7a6aedbaffbccd955a2111afebe11147dea994"
        ),
        .executableTarget(
            name: "Murmure",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
            ],
            path: "Sources/Murmure"
        )
    ]
)
