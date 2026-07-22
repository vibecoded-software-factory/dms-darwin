// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dms-darwin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "dms-darwin",
            path: "Sources/dms-darwin"
        )
    ]
)
