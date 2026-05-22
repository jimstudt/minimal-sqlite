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
        .systemLibrary(
            name: "CSQLite3",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "MinimalSQLite",
            dependencies: ["CSQLite3"]
        ),
        .testTarget(
            name: "MinimalSQLiteTests",
            dependencies: ["MinimalSQLite"]
        )
    ]
)
