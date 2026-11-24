// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SMCKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "FanControlHelper", dependencies: ["SMCKit"]),
        .executableTarget(
            name: "FanControl",
            dependencies: ["SMCKit"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
