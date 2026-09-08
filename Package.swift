// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "WakTrainerServer",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/vapor/vapor.git",
            from: "4.121.4"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.101.0"
        ),
        .package(
            url: "https://github.com/vapor/fluent.git",
            from: "4.9.0"
        ),
        .package(
            url: "https://github.com/vapor/fluent-postgres-driver.git",
            from: "2.12.0"
        ),
        .package(
            url: "https://github.com/vapor/jwt.git",
            from: "5.0.0"
        ),
        .package(
            url: "https://github.com/vapor/jwt-kit.git",
            // JWTKit 5.7.0's warnings-as-errors conflicts with Xcode's dependency warning suppression.
            exact: "5.6.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "WakTrainerServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WakTrainerServerTests",
            dependencies: [
                .target(name: "WakTrainerServer"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
] }
