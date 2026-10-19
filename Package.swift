// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "showup",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "showup", targets: ["showup"]),
        .executable(name: "showup-tests", targets: ["ShowupTests"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ShowupCore",
            path: "Sources/ShowupCore"
        ),
        .executableTarget(
            name: "showup",
            dependencies: ["ShowupCore"],
            path: "Sources/showup"
        ),
        .executableTarget(
            name: "ShowupTests",
            dependencies: ["ShowupCore"],
            path: "Tests/ShowupTests"
        )
    ]
)
