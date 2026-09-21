import Fluent
import FluentPostgresDriver
import Foundation
import Vapor

func configure(
    _ app: Application,
    environment: (String) -> String? = { Environment.get($0) }
) async throws {
    guard let port = Int(environment("PORT") ?? "8080"), (1...65535).contains(port) else {
        throw Abort(.internalServerError, reason: "PORT must be between 1 and 65535.")
    }
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = port

    var configuration: SQLPostgresConfiguration
    if let url = environment("DATABASE_URL") {
        // URL parsing errors may contain credentials. Only expose a fixed diagnostic.
        do {
            guard let components = URLComponents(string: url),
                  ["postgres", "postgresql"].contains(components.scheme ?? ""),
                  let host = components.host, !host.isEmpty,
                  let user = components.user, !user.isEmpty,
                  let password = components.password, !password.isEmpty,
                  components.path.count > 1,
                  (1...65535).contains(components.port ?? 5432) else {
                throw Abort(.internalServerError)
            }
            configuration = try SQLPostgresConfiguration(url: url)
        } catch {
            throw Abort(.internalServerError, reason: "DATABASE_URL must be a valid PostgreSQL URL with credentials and database name.")
        }
    } else {
        func value(_ key: String, localDefault: String? = nil) throws -> String {
            if let value = environment(key), !value.isEmpty { return value }
            if app.environment != .production, let localDefault { return localDefault }
            throw Abort(.internalServerError, reason: "\(key) is required.")
        }
        guard let databasePort = Int(environment("DATABASE_PORT") ?? "5432"),
              (1...65535).contains(databasePort) else {
            throw Abort(.internalServerError, reason: "DATABASE_PORT must be between 1 and 65535.")
        }
        configuration = try SQLPostgresConfiguration(
            hostname: value("DATABASE_HOST", localDefault: "127.0.0.1"),
            port: databasePort,
            username: value("DATABASE_USERNAME", localDefault: "waktrainer"),
            password: value("DATABASE_PASSWORD"),
            database: value("DATABASE_NAME", localDefault: "waktrainer"),
            tls: app.environment == .production ? .require(.init(configuration: .clientDefault)) : .disable
        )
    }
    // Explicit TLS override also applies to DATABASE_URL. Without it, URL TLS options are preserved.
    if let tlsMode = environment("DATABASE_TLS") {
        switch tlsMode {
        case "disable": configuration.coreConfiguration.tls = .disable
        case "require": configuration.coreConfiguration.tls = try .require(.init(configuration: .clientDefault))
        default: throw Abort(.internalServerError, reason: "DATABASE_TLS must be disable or require.")
        }
    }
    app.databases.use(.postgres(configuration: configuration), as: .psql)
    try routes(app)
}
