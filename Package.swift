// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "WakTrainerServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
    ],
    targets: [
        .executableTarget(name: "WakTrainerServer", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        ]),
        .testTarget(name: "WakTrainerServerTests", dependencies: [
            .target(name: "WakTrainerServer"),
            .product(name: "VaporTesting", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
        ]),
    ]
)
