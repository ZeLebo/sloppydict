// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyDict",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SloppyDict", targets: ["SloppyDict"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: []),
    ],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(
            name: "SloppyDict",
            dependencies: ["DictationCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
