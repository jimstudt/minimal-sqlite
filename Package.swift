// swift-tools-version: 6.2
import PackageDescription

var targets: [Target] = []
var minimalSQLiteDependencies: [Target.Dependency] = []

#if os(Linux)
targets.append(
    .systemLibrary(
        name: "CSQLite3",
        pkgConfig: "sqlite3",
        providers: [
            .apt(["libsqlite3-dev"])
        ]
    )
)
minimalSQLiteDependencies.append("CSQLite3")
#endif

targets.append(
    .target(
        name: "MinimalSQLite",
        dependencies: minimalSQLiteDependencies
    )
)

targets.append(
    .testTarget(
        name: "MinimalSQLiteTests",
        dependencies: ["MinimalSQLite"]
    )
)

let package = Package(
    name: "MinimalSQLite",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MinimalSQLite", targets: ["MinimalSQLite"])
    ],
    targets: targets
)
