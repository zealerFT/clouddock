// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CloudDock", targets: ["CloudDock"])],
    targets: [
        .target(name: "CloudDockCore"),
        .executableTarget(name: "CloudDock", dependencies: ["CloudDockCore"]),
        .executableTarget(name: "CloudDockChecks", dependencies: ["CloudDockCore"], path: "Tests/CloudDockCoreTests")
    ]
)
