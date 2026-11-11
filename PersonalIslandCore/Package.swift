// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PersonalIslandCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PersonalIslandCore", targets: ["PersonalIslandCore"])],
    targets: [
        .target(name: "PersonalIslandCore"),
        .testTarget(name: "PersonalIslandCoreTests", dependencies: ["PersonalIslandCore"])
    ]
)
