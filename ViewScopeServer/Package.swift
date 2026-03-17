// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewScopeServer",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "ViewScopeServer",
            targets: ["ViewScopeServer"]
        )
    ],
    targets: [
        .target(
            name: "ViewScopeServer",
            path: "Sources/ViewScopeServer"
        ),
        .testTarget(
            name: "ViewScopeServerTests",
            dependencies: ["ViewScopeServer"],
            path: "Tests/ViewScopeServerTests"
        )
    ]
)
