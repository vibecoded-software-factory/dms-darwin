// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dms-darwin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "dms-darwin",
            path: "Sources/dms-darwin",
            linkerSettings: [
                // Embed the Info.plist: a launchd process that touches a
                // TCC-guarded API (bluetooth) without a usage description is
                // killed outright.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
