@testable import WakTrainerServer
import Fluent
import Testing
import VaporTesting

@Suite("WakTrainerServer bootstrap")
struct WakTrainerServerTests {
    @Test("Health returns JSON without a database connection")
    func health() async throws {
        try await withApp(configure: { app in
            try await configure(app, environment: { key in
                ["DATABASE_PASSWORD": "test-only", "DATABASE_PORT": "1"][key]
            })
        }) { app in
            try await app.testing().test(.GET, "health", afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.contentType == .json)
                #expect(try response.content.decode(HealthResponse.self).status == "ok")
            })
        }
    }

    @Test("Application boots with Fluent configured and shuts down cleanly")
    func boot() async throws {
        try await withApp(configure: { app in
            try await configure(app, environment: { $0 == "DATABASE_PASSWORD" ? "test-only" : nil })
        }) { app in
            try await app.asyncBoot()
            #expect(app.databases.configuration(for: .psql) != nil)
        }
    }

    @Test("Invalid database settings fail configuration", arguments: [
        [:], ["DATABASE_PASSWORD": ""],
        ["DATABASE_PASSWORD": "test", "DATABASE_PORT": "invalid"],
        ["DATABASE_PASSWORD": "test", "DATABASE_PORT": "0"],
        ["DATABASE_PASSWORD": "test", "DATABASE_PORT": "65536"],
        ["DATABASE_PASSWORD": "test", "DATABASE_TLS": "invalid"],
        ["DATABASE_PASSWORD": "test", "PORT": "invalid"],
        ["DATABASE_PASSWORD": "test", "PORT": "0"],
        ["DATABASE_PASSWORD": "test", "PORT": "65536"],
        ["DATABASE_URL": ""],
        ["DATABASE_URL": "https://user:secret@example.com/db"],
        ["DATABASE_URL": "postgres://user:secret@db/"],
    ])
    func invalidConfiguration(values: [String: String]) async throws {
        try await withApp { app in
            await #expect(throws: Abort.self) {
                try await configure(app, environment: { values[$0] })
            }
        }
    }

    @Test("Railway PORT and DATABASE_URL work in production without local DB defaults")
    func railwayConfiguration() async throws {
        try await withApp { app in
            app.environment = .production
            try await configure(app, environment: { key in
                ["AUTHENTICATION_SERVER_URL": "http://authentication:8080",
                 "PORT": "19091",
                 "DATABASE_URL": "postgresql://user:test-only@db:5432/railway?sslmode=disable",
                 "DATABASE_PASSWORD": "", "DATABASE_PORT": "invalid"][key]
            })
            try await app.asyncBoot()
            #expect(app.http.server.configuration.hostname == "0.0.0.0")
            #expect(app.http.server.configuration.port == 19091)
            #expect(app.databases.configuration(for: .psql) != nil)
        }
    }

    @Test("Production requires explicit DB host, username and database", arguments: [
        ["DATABASE_PASSWORD": "test-only"],
        ["DATABASE_PASSWORD": "test-only", "DATABASE_HOST": "db"],
        ["DATABASE_PASSWORD": "test-only", "DATABASE_HOST": "db", "DATABASE_USERNAME": "app"],
    ])
    func productionRequiresConfiguration(values: [String: String]) async throws {
        try await withApp { app in
            app.environment = .production
            await #expect(throws: Abort.self) {
                try await configure(app, environment: { values[$0] })
            }
        }
    }

    @Test("Invalid URL diagnostics do not expose credentials")
    func redactedURL() async throws {
        try await withApp { app in
            do {
                try await configure(app, environment: {
                    $0 == "DATABASE_URL" ? "invalid://user:sensitive-test-password@host/db" : nil
                })
                Issue.record("Configuration should fail")
            } catch let error as Abort {
                #expect(!String(describing: error).contains("sensitive-test-password"))
                #expect(error.reason.contains("DATABASE_URL"))
            }
        }
    }

    @Test("PostgreSQL accepts a Fluent connection",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "1"))
    func postgresConnection() async throws {
        try await withApp(configure: { try await configure($0) }) { app in
            try await app.asyncBoot()
            try await app.db.withConnection { connection in
                connection.eventLoop.makeSucceededVoidFuture()
            }.get()
        }
    }
}
