// swift-tools-version: 6.1
// This is a Skip (https://skip.tools) package.
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
        .package(url: "https://github.com/needletails/Specs.git", from: "137.7151.11"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.3.0"),
        .package(url: "https://github.com/needletails/needletail-logger.git", from: "3.1.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/needletails/needletail-algorithms.git", from: "2.0.0"),
        .package(url: "https://github.com/needletails/needletail-media-kit.git", revision: "bd2bb653fefb0b10369e6b133f5ed3d06ff98320"),
        .package(url: "https://github.com/needletails/double-ratchet-kit.git", from: "2.0.2"),
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
        .testTarget(
            name: "PQSRTCTests",
            dependencies: [
                "PQSRTC",
                .product(name: "SkipTest", package: "skip"),
            ],
            path: "Tests/PQSRTCTests",
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
        .testTarget(
            name: "PQSRTCCompiledSwiftTests",
            dependencies: [
                "PQSRTC",
                .product(name: "DoubleRatchetKit", package: "double-ratchet-kit"),
                .product(name: "NeedleTailLogger", package: "needletail-logger"),
                .product(name: "WebRTC", package: "Specs", condition: .when(platforms: [.iOS, .macOS]))
            ],
            path: "Tests/PQSRTCCompiledSwiftTests"
        ),
    ]
)

if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    // all library types must be dynamic to support bridging
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
