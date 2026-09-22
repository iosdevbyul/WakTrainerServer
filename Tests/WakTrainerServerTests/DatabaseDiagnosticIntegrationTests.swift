@testable import WakTrainerServer
import FluentPostgresDriver
import NIOSSL
import Testing
import VaporTesting

@Suite("Database diagnostic PostgreSQL integration")
struct DatabaseDiagnosticIntegrationTests {
    @Test("The configured Fluent connection reports actual TLS and read-only state",
          .enabled(if: Environment.get("RUN_DATABASE_DIAGNOSTIC_TESTS") == "1"),
          arguments: [true, false])
    func configuredConnection(tls: Bool) async throws {
        // This opt-in fixture is restricted to a local disposable database.
        try #require(["127.0.0.1", "localhost"].contains(Environment.get("DATABASE_HOST") ?? ""))
        try #require(Environment.get("DATABASE_NAME") == "waktrainer")
        try #require(Environment.get("DATABASE_USERNAME") == "waktrainer_app")
        try await withApp(configure: { app in
            try await configure(app, environment: { key in
                if key == "DATABASE_URL" { return nil }
                if key == "DATABASE_TLS" { return tls ? "require" : "disable" }
                return Environment.get(key)
            })
            if tls {
                // Trust only the disposable fixture certificate, without changing system trust
                // or weakening certificate/hostname verification in production configuration.
                var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
                tlsConfiguration.trustRoots = .file(try #require(Environment.get("TEST_DATABASE_CA_FILE")))
                app.databases.use(.postgres(configuration: .init(
                    hostname: try #require(Environment.get("DATABASE_HOST")),
                    port: try #require(Int(Environment.get("DATABASE_PORT") ?? "")),
                    username: "waktrainer_app", password: Environment.get("DATABASE_PASSWORD"),
                    database: "waktrainer", tls: .require(try NIOSSLContext(configuration: tlsConfiguration))
                )), as: .psql)
            }
        }) { app in
            let snapshot = try await DatabaseDiagnostic.load(from: app)
            #expect(snapshot.databaseMatches)
            #expect(snapshot.userMatches)
            #expect(snapshot.readOnly)
            #expect(snapshot.canConnect)
            #expect(snapshot.publicUsage)
            #expect(snapshot.tlsEnabled == tls)
            let report = await DatabaseDiagnostic.run { snapshot }
            #expect(report.passed == tls)
            app.environment.arguments = ["WakTrainerServer", "verify-database"]
            if tls {
                try await app.startup()
            } else {
                await #expect(throws: DatabaseDiagnosticFailure.self) {
                    try await app.startup()
                }
            }
        }
    }
}
