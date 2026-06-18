// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sift", targets: ["Sift"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Sift",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Sift",
            // Resources are copied straight into the .app's Contents/Resources by
            // the build scripts and loaded via Bundle.main — not via a SwiftPM
            // resource bundle, whose accessor bakes in a machine-specific build
            // path and looks in the wrong place inside a hand-assembled .app.
            exclude: ["Resources"]
        )
    ]
)
