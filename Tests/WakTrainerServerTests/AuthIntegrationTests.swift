@testable import WakTrainerServer
import Fluent
import SQLKit
import FluentPostgresDriver
import JWT
import Testing
import VaporTesting

@Suite("PostgreSQL auth integration")
struct AuthIntegrationTests {
    private func request(_ app: Application, _ method: HTTPMethod, _ path: String,
                         token: String? = nil, body: [String: String] = [:]) async throws -> TestingHTTPResponse {
        try await app.sendRequest(method, "auth/" + path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if !body.isEmpty { try req.content.encode(body) }
        })
    }

    @Test(.enabled(if: Environment.get("TEST_DATABASE_NAME") != nil))
    func accountLifecycle() async throws {
        let name = try #require(Environment.get("TEST_DATABASE_NAME"))
        // Only run migrations in an explicitly selected disposable test database.
        try #require(name.hasPrefix("waktrainer_test_"))
        try await withApp(configure: { app in
            app.databases.use(.postgres(configuration: .init(
                hostname: Environment.get("TEST_DATABASE_HOST") ?? "127.0.0.1",
                port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 55439,
                username: Environment.get("TEST_DATABASE_USERNAME") ?? "postgres",
                password: Environment.get("TEST_DATABASE_PASSWORD"),
                database: name, tls: .disable
            )), as: .psql)
            await app.jwt.keys.add(hmac: .init(from: AuthSession.randomToken()), digestAlgorithm: .sha256)
            app.migrations.add(CreateUserMigration(), CreateRefreshTokenMigration(), CreateLoginRateLimitMigration())
            try routes(app)
            try await app.autoMigrate()
        }) { app in
            let email = UUID().uuidString + "@example.com"
            let password = String(AuthSession.randomToken().prefix(16))
            let newPassword = String(AuthSession.randomToken().prefix(16))
            let credentials = ["email": email, "password": password]
            let signup = try await request(app, .POST, "signup", body: credentials)
            try #require(signup.status == .ok)
            let first = try signup.content.decode(SessionResponseDTO.self)
            #expect(first.accessToken.hasPrefix("eyJ"))
            let refresh = try #require(first.refreshToken)
            let stored = try #require(try await RefreshToken.query(on: app.db).first())
            #expect(stored.tokenHash != refresh)
            #expect(stored.tokenHash == AuthSession.hash(refresh))
            let duplicate = try await request(app, .POST, "signup", body: credentials)
            #expect(duplicate.status == .conflict)
            let wrongLogin = try await request(app, .POST, "login", body: ["email": email, "password": newPassword])
            #expect(wrongLogin.status == .unauthorized)
            let profile = try await request(app, .GET, "me", token: first.accessToken)
            #expect(profile.status == .ok)
            #expect(try profile.content.decode(UserResponseDTO.self).email == email)
            let invalid = try await request(app, .GET, "me", token: first.accessToken + "x")
            #expect(invalid.status == .unauthorized)

            // A refresh token can be consumed only once, even concurrently.
            async let refreshA = request(app, .POST, "refresh", body: ["refreshToken": refresh])
            async let refreshB = request(app, .POST, "refresh", body: ["refreshToken": refresh])
            let responses = try await [refreshA, refreshB]
            #expect(responses.filter { $0.status == .ok }.count == 1)
            #expect(responses.filter { $0.status == .unauthorized }.count == 1)
            let rotated = try #require(responses.first { $0.status == .ok }).content.decode(SessionResponseDTO.self)
            let oldAccess = try await request(app, .GET, "me", token: first.accessToken)
            #expect(oldAccess.status == .unauthorized)
            let logout = try await request(app, .POST, "logout", token: rotated.accessToken)
            #expect(logout.status == .ok)
            let loggedOut = try await request(app, .GET, "me", token: rotated.accessToken)
            #expect(loggedOut.status == .unauthorized)
            let loggedOutRefresh = try await request(app, .POST, "refresh", body: ["refreshToken": try #require(rotated.refreshToken)])
            #expect(loggedOutRefresh.status == .unauthorized)

            let login = try await request(app, .POST, "login", body: credentials)
            let session = try login.content.decode(SessionResponseDTO.self)
            let secondLogin = try await request(app, .POST, "login", body: credentials)
            let otherSession = try secondLogin.content.decode(SessionResponseDTO.self)
            let wrongChange = try await request(app, .POST, "change-password", token: session.accessToken,
                body: ["currentPassword": newPassword, "newPassword": String(AuthSession.randomToken().prefix(16))])
            #expect(wrongChange.status == .unauthorized)
            let changed = try await request(app, .POST, "change-password", token: session.accessToken,
                body: ["currentPassword": password, "newPassword": newPassword])
            #expect(changed.status == .ok)
            for old in [session, otherSession] {
                let denied = try await request(app, .GET, "me", token: old.accessToken)
                #expect(denied.status == .unauthorized)
                let deniedRefresh = try await request(app, .POST, "refresh", body: ["refreshToken": try #require(old.refreshToken)])
                #expect(deniedRefresh.status == .unauthorized)
            }
            let oldPassword = try await request(app, .POST, "login", body: credentials)
            #expect(oldPassword.status == .unauthorized)
            let updatedLogin = try await request(app, .POST, "login", body: ["email": email, "password": newPassword])
            try #require(updatedLogin.status == .ok)
            let updated = try updatedLogin.content.decode(SessionResponseDTO.self)
            let withdraw = try await request(app, .DELETE, "withdraw", token: updated.accessToken)
            #expect(withdraw.status == .ok)
            #expect(try await User.query(on: app.db).filter(\.$email == email).count() == 0)
            #expect(try await RefreshToken.query(on: app.db).count() == 0)
            let deletedAccess = try await request(app, .GET, "me", token: updated.accessToken)
            #expect(deletedAccess.status == .unauthorized)
            let deletedLogin = try await request(app, .POST, "login", body: ["email": email, "password": newPassword])
            #expect(deletedLogin.status == .unauthorized)
            try await verifyRateLimits(app)
            try await app.autoRevert()
        }
    }
    private func verifyRateLimits(_ app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("DELETE FROM login_rate_limits").run()
        let email = UUID().uuidString + "@example.com"
        let password = String(AuthSession.randomToken().prefix(16))
        // Nonexistent accounts get exactly the same quota, without needing a user row.
        for _ in 0..<10 {
            let response = try await request(app, .POST, "login", body: ["email": email, "password": password])
            #expect(response.status == .unauthorized)
        }
        let blocked = try await request(app, .POST, "login", body: ["email": email.uppercased(), "password": password])
        #expect(blocked.status == .tooManyRequests)
        let retryAfter = try #require(blocked.headers.first(name: "Retry-After").flatMap(Int.init))
        #expect((1...900).contains(retryAfter))

        // Expired windows allow attempts again without sleeping or changing application clocks.
        try await sql.raw("UPDATE login_rate_limits SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'").run()
        let reset = try await request(app, .POST, "login", body: ["email": email, "password": password])
        #expect(reset.status == .unauthorized)

        // Concurrent consumers share an atomic quota in PostgreSQL.
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        try await LoginRateLimiter.consume(key: "test:concurrent", limit: 5, seconds: 60, on: app.db)
                        return true
                    } catch let error as Abort where error.status == .tooManyRequests {
                        return false
                    }
                }
            }
            var allowed = 0
            for try await result in group { if result { allowed += 1 } }
            return allowed
        }
        #expect(results == 5)

        // IP limiting happens even before JSON decoding; spoofed forwarding headers do not bypass it.
        try await sql.raw("DELETE FROM login_rate_limits").run()
        for attempt in 1...31 {
            let response = try await app.sendRequest(.POST, "auth/login", headers: [
                "X-Forwarded-For": "192.0.2." + String(attempt)
            ])
            #expect(response.status == (attempt <= 30 ? .badRequest : .tooManyRequests))
        }
    }

}
