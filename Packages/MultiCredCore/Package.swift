// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiCredCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MultiCredCore", targets: ["MultiCredCore"]),
    ],
    targets: [
        .target(
            name: "MultiCredCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "MultiCredCoreTests",
            dependencies: ["MultiCredCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
