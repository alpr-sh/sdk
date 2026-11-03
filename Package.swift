// swift-tools-version:6.0
// SwiftPM reads a package at the root of its repository, so this file exposes
// the Swift SDK that sdk/generator writes under swift/ to
// .package(url: "https://github.com/alpr-sh/sdk", from: "X.Y.Z"). It is
// written by hand: keep it equal to swift/Package.swift but for the paths.
import PackageDescription

let package = Package(
    name: "Alpr",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "Alpr", targets: ["Alpr"])
    ],
    targets: [
        .target(name: "Alpr", path: "swift/Sources/Alpr"),
        .testTarget(name: "AlprTests", dependencies: ["Alpr"], path: "swift/Tests/AlprTests"),
    ]
)
