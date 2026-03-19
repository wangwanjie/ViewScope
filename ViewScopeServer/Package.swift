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
            targets: ["ViewScopeServer", "ViewScopeServerBootstrap"]
        )
    ],
    targets: [
        .target(
            name: "ViewScopeServer",
            dependencies: ["ViewScopeServerBootstrap"],
            path: "Sources/ViewScopeServer",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_ViewScopeServerBootstrapAnchor"], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "ViewScopeServerBootstrap",
            path: "Sources/ViewScopeServerBootstrap",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "ViewScopeServerTests",
            dependencies: ["ViewScopeServer"],
            path: "Tests/ViewScopeServerTests"
        )
    ]
)
