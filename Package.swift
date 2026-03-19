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
            targets: ["ViewScopeServer", "ViewScopeServerBootstrap"]
        )
    ],
    targets: [
        .target(
            name: "ViewScopeServer",
            dependencies: ["ViewScopeServerBootstrap"],
            path: "ViewScopeServer/Sources/ViewScopeServer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_ViewScopeServerBootstrapAnchor"], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "ViewScopeServerBootstrap",
            path: "ViewScopeServer/Sources/ViewScopeServerBootstrap",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "ViewScopeServerTests",
            dependencies: ["ViewScopeServer"],
            path: "ViewScopeServer/Tests/ViewScopeServerTests"
        )
    ]
)
