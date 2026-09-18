// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "pqs-rtc",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "PQSRTC", targets: ["PQSRTC"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.6.32"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.2"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.10.0"),
        .package(url: "https://github.com/needletails/Specs.git", from: "144.7559.10"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.3.0"),
        .package(url: "https://github.com/needletails/needletail-logger.git", from: "3.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/needletails/needletail-algorithms.git", from: "2.0.5"),
        .package(url: "https://github.com/needletails/needletail-media-kit.git", from: "1.1.0"),
        .package(url: "https://github.com/needletails/double-ratchet-kit.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "PQSRTC",
            dependencies: [
            .product(name: "SkipFuse", package: "skip-fuse"),
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "NeedleTailLogger", package: "needletail-logger"),
            .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "NeedleTailAlgorithms", package: "needletail-algorithms"),
            .product(name: "DoubleRatchetKit", package: "double-ratchet-kit"),
            .product(name: "NeedleTailMediaKit", package: "needletail-media-kit", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "WebRTC", package: "Specs", condition: .when(platforms: [.iOS, .macOS]))
        ], resources: [
            .process("Resources"),
            .process("Rendering/MetalProcessors/MetalShaders/RenderingShaders.metal")
        ],
                plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

let skipBridge = (Context.environment["SKIP_BRIDGE"] ?? "0") != "0"

if skipBridge {
    // Skip Android: dynamic product + Skip test module only.
    package.products = package.products.map { product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    }
    package.targets.append(
        .testTarget(
            name: "PQSRTCTests",
            dependencies: [
                "PQSRTC",
                .product(name: "SkipTest", package: "skip"),
            ],
            path: "Tests/PQSRTCTests",
            plugins: [.plugin(name: "skipstone", package: "skip")]
        )
    )
} else {
    // Apple-only (WebRTC, CoreGraphics, CoreImage). Keep this off the
    // `skip android build --build-tests` graph.
    // Swift 6.4 `swift test` must pass `--build-system native` (see README).
    package.targets.append(
        .testTarget(
            name: "PQSRTCCompiledSwiftTests",
            dependencies: [
                "PQSRTC",
                .product(name: "DoubleRatchetKit", package: "double-ratchet-kit"),
                .product(name: "NeedleTailLogger", package: "needletail-logger"),
                .product(name: "WebRTC", package: "Specs", condition: .when(platforms: [.iOS, .macOS]))
            ],
            path: "Tests/PQSRTCCompiledSwiftTests"
        )
    )
}
