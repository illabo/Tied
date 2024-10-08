// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Tied",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "Tied",
            targets: ["Tied"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/markrenaud/UInt4", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "Tied",
            dependencies: ["UInt4"]
        ),
        .testTarget(
            name: "TiedTests",
            dependencies: ["Tied"]
        ),
        .executableTarget(
            name: "Example",
            dependencies: ["Tied"]
        )
    ]
)
