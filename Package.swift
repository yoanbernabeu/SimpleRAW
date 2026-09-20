// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleRAW",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RawEngine", targets: ["RawEngine"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Backup", targets: ["Backup"]),
        .executable(name: "simpleraw", targets: ["simpleraw"]),
        .executable(name: "SimpleRAWApp", targets: ["SimpleRAWApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "RawEngine",
            plugins: ["MetalKernels"]
        ),
        .executableTarget(
            name: "simpleraw",
            dependencies: [
                "RawEngine",
                "Catalog",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "Catalog",
            dependencies: ["RawEngine"],
            // The SQLite that ships with macOS: no dependency to fetch or to keep up to date.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "Backup", dependencies: ["Catalog"]),
        .target(name: "SimpleRAWUI", dependencies: ["RawEngine", "Catalog", "Backup"]),
        .executableTarget(name: "SimpleRAWApp", dependencies: ["SimpleRAWUI", "Catalog", "RawEngine"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "RawEngineTests", dependencies: ["RawEngine", "TestSupport"]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "TestSupport"]),
        .testTarget(name: "BackupTests", dependencies: ["Backup"]),
        .testTarget(name: "SimpleRAWUITests", dependencies: ["SimpleRAWUI", "TestSupport"]),
        .plugin(name: "MetalKernels", capability: .buildTool()),
    ]
)
