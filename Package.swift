// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "Planetscale",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Planetscale", targets: ["Planetscale"]),
    ],
    dependencies: [
         .package(url: "https://github.com/swift-cloud/Compute", from: "2.0.0")
    ],
    targets: [
        .target(name: "Planetscale", dependencies: ["Compute"])
    ]
)
