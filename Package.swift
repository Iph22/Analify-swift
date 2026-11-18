// swift-tools-version:5.7
// Analify for iPhone, iPad and Mac apps. https://analify.dev/docs#apps
import PackageDescription

let package = Package(
    name: "Analify",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "Analify", targets: ["Analify"]),
    ],
    targets: [
        .target(name: "Analify", path: "Sources/Analify"),
        .testTarget(name: "AnalifyTests", dependencies: ["Analify"], path: "Tests/AnalifyTests"),
    ]
)
