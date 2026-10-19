// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "showup",
    // showup runs on the macOS that ships with the Swift that builds it.
    // Nothing here is version gated: the floor is the Testing framework, not
    // any API showup uses.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "showup", targets: ["showup"])
    ],
    targets: [
        // Pure logic. Knows about clocks, schedules and the alarm, and about
        // nothing else: no Foundation process spawning, no macOS.
        .target(name: "ShowupCore"),

        // The platform boundary. Every command this program runs, and every
        // parser for the output of those commands, lives here so that it can
        // be tested against verbatim real output.
        .target(name: "ShowupMac", dependencies: ["ShowupCore"]),

        .executableTarget(
            name: "showup",
            dependencies: ["ShowupCore", "ShowupMac"],
            path: "Sources/showup"
        ),

        .testTarget(
            name: "ShowupTests",
            dependencies: ["ShowupCore", "ShowupMac"],
            path: "Tests/ShowupTests"
        )
    ]
)