// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Squall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Squall",
            path: "Sources/Squall",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "SquallTests",
            dependencies: ["Squall"],
            path: "Tests/SquallTests"
        ),
    ]
)
