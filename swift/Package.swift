// swift-tools-version:6.0
// Alpr.sh's SDK for Swift, written by sdk/generator; do not edit. The
// repository's root Package.swift builds these same sources, so SwiftPM can
// depend on https://github.com/alpr-sh/sdk.
import PackageDescription

let package = Package(
    name: "Alpr",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "Alpr", targets: ["Alpr"])
    ],
    targets: [
        .target(name: "Alpr"),
        .testTarget(name: "AlprTests", dependencies: ["Alpr"]),
    ]
)
