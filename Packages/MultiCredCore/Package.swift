// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiCredCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MultiCredCore", targets: ["MultiCredCore"]),
        .library(name: "MultiCredHelp", targets: ["MultiCredHelp"]),
        .executable(name: "multicred-mcp", targets: ["multicred-mcp"]),
    ],
    targets: [
        .target(
            name: "MultiCredCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        // Read-only help MCP server (guide + diagnostics). No networking, no writes.
        .target(
            name: "MultiCredHelp",
            dependencies: ["MultiCredCore"],
            resources: [.embedInCode("Guide/guia.md")]
        ),
        .executableTarget(
            name: "multicred-mcp",
            dependencies: ["MultiCredHelp", "MultiCredCore"]
        ),
        .testTarget(
            name: "MultiCredCoreTests",
            dependencies: ["MultiCredCore", "MultiCredHelp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
