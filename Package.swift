// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MinimalSQLite",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MinimalSQLite", targets: ["MinimalSQLite"])
    ],
    targets: [
        .target(
            name: "MinimalSQLite",
            dependencies: []
        ),
        .testTarget(
            name: "MinimalSQLiteTests",
            dependencies: ["MinimalSQLite"]
        )
    ]
)
