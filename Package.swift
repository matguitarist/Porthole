// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/matguitarist/LogKit", from: "0.6.0"),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "PortholeKit", dependencies: [.product(name: "LogKit", package: "LogKit")]),
        .executableTarget(
            name: "Porthole",
            dependencies: ["PortholeKit", .product(name: "LogKitUI", package: "LogKit")],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PortholeKitTests", dependencies: ["PortholeKit", .product(name: "LogKit", package: "LogKit")]),
    ]
)
