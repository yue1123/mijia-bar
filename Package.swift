// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MijiaBar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MiioKit"),
        .executableTarget(name: "MijiaBar", dependencies: ["MiioKit"]),
        .executableTarget(name: "miio", dependencies: ["MiioKit"]),
    ],
    swiftLanguageModes: [.v5]
)
