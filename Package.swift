// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MRReachability",
    platforms: [
        .iOS(.v12), .macOS(.v10_14), .tvOS(.v12), .watchOS(.v5)
    ],
    products: [
        .library(name: "MRReachability", targets: ["MRReachability"])
    ],
    targets: [
        .target(
            name: "MRReachability",
            path: "Sources/MRReachability",
            linkerSettings: []
        )
    ]
)

