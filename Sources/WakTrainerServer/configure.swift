import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import JWTKit

func configure(_ app: Application) async throws {
    let databasePrefix = app.environment == .testing ? "TEST_DATABASE_" : "DATABASE_"
    let databaseName = Environment.get(databasePrefix + "NAME") ?? "waktrainer"
    if app.environment == .testing, databaseName != "waktrainer_test_auth" {
        throw Abort(.internalServerError, reason: "Testing requires TEST_DATABASE_NAME=waktrainer_test_auth.")
    }
    guard let databasePassword = Environment.get(databasePrefix + "PASSWORD"), !databasePassword.isEmpty else {
        throw Abort(.internalServerError, reason: "\(databasePrefix)PASSWORD environment variable is required.")
    }

    let postgresConfiguration = SQLPostgresConfiguration(
        hostname: Environment.get(databasePrefix + "HOST") ?? "127.0.0.1",
        port: Environment.get(databasePrefix + "PORT").flatMap(Int.init) ?? 5432,
        username: Environment.get(databasePrefix + "USERNAME") ?? "vapor",
        password: databasePassword,
        database: databaseName,
        tls: .disable
    )

    app.databases.use(
        .postgres(configuration: postgresConfiguration),
        as: .psql
    )

    // Audit writes use a separate small pool so a slow audit table cannot occupy auth connections.
    app.databases.use(.postgres(configuration: postgresConfiguration,
        maxConnectionsPerEventLoop: 1, connectionPoolTimeout: .milliseconds(250)), as: .audit, isDefault: false)

    app.databases.use(.postgres(configuration: postgresConfiguration,
        maxConnectionsPerEventLoop: 1, connectionPoolTimeout: .seconds(1)), as: .maintenance, isDefault: false)
    app.asyncCommands.use(MaintenanceCommand(), as: "maintenance")

    guard let jwtSecret = Environment.get("JWT_SECRET"),
          !jwtSecret.isEmpty else {
        throw Abort(.internalServerError, reason: "JWT_SECRET environment variable is required.")
    }

    let hmacKey = HMACKey(from: jwtSecret)
    let digestAlgorithm = DigestAlgorithm.sha256

    await app.jwt.keys.add(
        hmac: hmacKey,
        digestAlgorithm: digestAlgorithm
    )

    app.migrations.add(CreateUserMigration())
    app.migrations.add(CreateRefreshTokenMigration())
    app.migrations.add(CreateLoginRateLimitMigration())
    app.migrations.add(CreatePasswordResetTokenMigration())
    app.migrations.add(CreateEmailRateLimitMigration())
    app.migrations.add(AddEmailVerificationMigration())
    app.migrations.add(AddEmailChangeMigration())
    app.migrations.add(AddSessionMetadataMigration())
    app.migrations.add(IndexSessionUserExpiryMigration())
    app.migrations.add(CreateAuditLogMigration())
    app.migrations.add(IndexMaintenanceExpiryMigration())
    APIErrorMiddleware.install(on: app)
    try routes(app)
}
