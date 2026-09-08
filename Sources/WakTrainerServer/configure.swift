import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import JWTKit

func configure(_ app: Application) async throws {
    guard let databasePassword = Environment.get("DATABASE_PASSWORD"), !databasePassword.isEmpty else {
        throw Abort(.internalServerError, reason: "DATABASE_PASSWORD environment variable is required.")
    }

    let postgresConfiguration = SQLPostgresConfiguration(
        hostname: Environment.get("DATABASE_HOST") ?? "127.0.0.1",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor",
        password: databasePassword,
        database: Environment.get("DATABASE_NAME") ?? "waktrainer",
        tls: .disable
    )

    app.databases.use(
        .postgres(configuration: postgresConfiguration),
        as: .psql
    )

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
    try routes(app)
}
