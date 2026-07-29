// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlowStack",
    platforms: [.iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "FlowStack",
            targets: ["FlowStack"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        // NB: the swiftui-cached-async-image dependency was dropped — the library
        // never imports it (it was only a README recommendation, used by the
        // example app) and its 2.1.2 manifest doesn't compile, which froze
        // dependency resolution for every consumer.
        .target(
            name: "FlowStack"),
        .testTarget(
            name: "FlowStackTests",
            dependencies: ["FlowStack"]),
    ]
)
