// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "PortholeKit"),
        .executableTarget(
            name: "Porthole",
            dependencies: ["PortholeKit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PortholeKitTests", dependencies: ["PortholeKit"]),
    ]
)
