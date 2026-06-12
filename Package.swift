// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mado",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mado",
            resources: [.copy("Resources")]
        )
    ]
)
