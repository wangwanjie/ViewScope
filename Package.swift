// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewScope",
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
            path: "ViewScopeServer/Sources/ViewScopeServer"
        ),
        .testTarget(
            name: "ViewScopeServerTests",
            dependencies: ["ViewScopeServer"],
            path: "ViewScopeServer/Tests/ViewScopeServerTests"
        )
    ]
)
