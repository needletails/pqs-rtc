// swift-tools-version: 6.0
// This is a Skip (https://skip.tools) package.
import PackageDescription

let package = Package(
    name: "needletail-rtc",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "NeedleTailRTC", type: .dynamic, targets: ["NeedleTailRTC"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.6.27"),
        .package(url: "https://source.skip.tools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.10.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "138.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.3.0"),
        .package(url: "https://github.com/needletails/needletail-logger.git", from: "3.1.2"),
        .package(url: "https://github.com/needletails/needletail-algorithms.git", from: "2.0.0"),
        .package(url: "https://github.com/needletails/needletail-media-kit.git", from: "1.0.8")
    ],
    targets: [
        .target(name: "NeedleTailRTC", dependencies: [
            .product(name: "SkipFuse", package: "skip-fuse"),
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "NeedleTailLogger", package: "needletail-logger"),
            .product(name: "NeedleTailAlgorithms", package: "needletail-algorithms"),
            .product(name: "NeedleTailMediaKit", package: "needletail-media-kit", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS, .macOS])),
        ], resources: [
            .process("Resources"),
        ], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(
            name: "NeedleTailRTCTests",
            dependencies: [
                "NeedleTailRTC",
                .product(name: "SkipTest", package: "skip"),
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Tests/NeedleTailRTCTests",
            resources: [.process("Resources")],
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
    ]
)
