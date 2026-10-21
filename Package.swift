// swift-tools-version: 6.0
import PackageDescription

/// What static libghostty needs from the system.
let ghosttyLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("Carbon"),
    .linkedFramework("CoreText"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("IOSurface"),
    .linkedFramework("UniformTypeIdentifiers")
]

let package = Package(
    name: "Wireline",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Wireline", targets: ["Wireline"]),
        .library(name: "WirelineCore", targets: ["WirelineCore"])
    ],
    dependencies: [
        // Official 1.20.0 + one-line Metal fix (premultiplied clear colour for backgroundOpacity < 1).
        .package(url: "https://github.com/almightyYantao/SwiftTerm.git", revision: "6d4db53cc5ec89b482e23aee6820f1c954adc378"),
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", from: "1.5.2"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "WirelineCore"
        ),
        // libghostty (static lib + ghostty.h). ~150 MB, never committed: run
        // scripts/fetch-ghosttykit.sh once to put it in Vendor/.
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .executableTarget(
            name: "Wireline",
            dependencies: [
                "WirelineCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Inject", package: "Inject"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Sparkle", package: "Sparkle"),
                "GhosttyKit"
            ],
            exclude: ["Ghostty/LICENSE-ghostty"],
            // `-interposable` lets InjectionIII hot-swap functions at runtime.
            // Debug-only, so release bundles are unaffected.
            linkerSettings: ghosttyLinkerSettings + [
                .unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "WirelineCoreTests",
            dependencies: ["WirelineCore"]
        ),
        // libghostty engine end-to-end (opens a window + shell; skipped unless
        // WIRELINE_GHOSTTY_HARNESS=1).
        .testTarget(
            name: "WirelineGhosttyHarness",
            dependencies: ["Wireline", "GhosttyKit"]
        )
    ]
)
