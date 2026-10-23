// swift-tools-version: 6.0
import PackageDescription
import Foundation

/// Package root, for the vendored FreeRDP (see scripts/fetch-freerdp.sh).
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

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

/// What static FreeRDP (+ its builtin channels and OpenSSL) needs from the system.
let freerdpLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["\(packageRoot)/Vendor/FreeRDP/lib/libFreeRDP.a"]),
    .linkedLibrary("z"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("Security"),
    .linkedFramework("SystemConfiguration"),
    .linkedFramework("AudioToolbox"),
    .linkedFramework("CoreAudio"),
    .linkedFramework("IOKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Carbon")
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
        // The C side of RDP panes: FreeRDP callbacks, its event-loop thread,
        // a shadow framebuffer. Swift talks to it through include/wlrdp.h only.
        // FreeRDP 3 + OpenSSL (static, ~35 MB universal) is never committed: run
        // scripts/fetch-freerdp.sh (--build) once to put it in Vendor/FreeRDP.
        // Not a binaryTarget: its headers would land in the include dir shared
        // with GhosttyKit, whose umbrella module map would swallow them.
        .target(
            name: "CFreeRDPShim",
            cSettings: [.unsafeFlags(["-I\(packageRoot)/Vendor/FreeRDP/include"])],
            linkerSettings: freerdpLinkerSettings
        ),
        .executableTarget(
            name: "Wireline",
            dependencies: [
                "WirelineCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Inject", package: "Inject"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Sparkle", package: "Sparkle"),
                "GhosttyKit",
                "CFreeRDPShim"
            ],
            exclude: ["Ghostty/LICENSE-ghostty"],
            // The Vendor/ GhosttyKit is Wireline's Ghostty fork (manual-IO termio,
            // last-command output, case-sensitive search). Drop this to build
            // against stock libghostty: the ghostty engine then stays off.
            swiftSettings: [.define("WIRELINE_GHOSTTY_MANUAL_IO")],
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
            dependencies: ["Wireline", "GhosttyKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
        )
    ]
)
