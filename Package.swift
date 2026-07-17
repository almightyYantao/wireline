// swift-tools-version: 6.0
import PackageDescription

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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", from: "1.5.2"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "WirelineCore"
        ),
        .executableTarget(
            name: "Wireline",
            dependencies: [
                "WirelineCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Inject", package: "Inject"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            // `-interposable` lets InjectionIII hot-swap functions at runtime.
            // Debug-only, so release bundles are unaffected.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "WirelineCoreTests",
            dependencies: ["WirelineCore"]
        )
    ]
)
