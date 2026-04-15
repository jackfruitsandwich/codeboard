// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "codeboard",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "codeboard",
            targets: ["Codeboard"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Codeboard",
            dependencies: ["GhosttyKit"],
            path: "Sources/Codeboard",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("WebKit"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
