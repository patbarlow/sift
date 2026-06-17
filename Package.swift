// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sift", targets: ["Sift"])
    ],
    targets: [
        .executableTarget(
            name: "Sift",
            path: "Sources/Sift",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
