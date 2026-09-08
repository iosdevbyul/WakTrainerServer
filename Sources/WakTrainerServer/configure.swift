import Vapor
import Fluent
import FluentPostgresDriver

func configure(_ app: Application) async throws {
    let postgresConfiguration = SQLPostgresConfiguration(
        hostname: "127.0.0.1",
        port: 5432,
        username: "vapor",
        password: "vapor",
        database: "waktrainer",
        tls: .disable
    )

    app.databases.use(
        .postgres(configuration: postgresConfiguration),
        as: .psql
    )
    
    app.migrations.add(CreateUserMigration())

    try routes(app)
}
