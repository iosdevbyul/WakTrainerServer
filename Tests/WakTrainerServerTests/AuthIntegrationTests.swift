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

    @Test
    func accountLifecycle() async throws {
        let emailService = MockEmailService()
        try await withApp(configure: { app in
            // Application.make loads .env before this closure runs.
            // Missing or unsafe configuration must fail instead of silently skipping.
            let name = try #require(Environment.get("TEST_DATABASE_NAME"))
            try #require(name == "waktrainer_test_auth")
            app.databases.use(.postgres(configuration: .init(
                hostname: Environment.get("TEST_DATABASE_HOST") ?? "127.0.0.1",
                port: Environment.get("TEST_DATABASE_PORT").flatMap(Int.init) ?? 5432,
                username: Environment.get("TEST_DATABASE_USERNAME") ?? "vapor",
                password: Environment.get("TEST_DATABASE_PASSWORD"),
                database: name, tls: .disable
            )), as: .psql)
            await app.jwt.keys.add(hmac: .init(from: AuthSession.randomToken()), digestAlgorithm: .sha256)
            app.migrations.add(
                CreateUserMigration(),
                CreateRefreshTokenMigration(),
                CreateLoginRateLimitMigration(),
                CreatePasswordResetTokenMigration(),
                CreateEmailRateLimitMigration()
            )
            try app.register(collection: AuthController(
                emailService: EmailService(transport: emailService),
                passwordResetURLBase: "https://example.com/reset-password"
            ))
            try await app.autoMigrate()
        }) { app in
            // Valid forgot-password requests query the database, even for unknown users.
            let forgot = try await request(app, .POST, "forgot-password", body: [
                "email": UUID().uuidString + "@example.com"
            ])
            #expect(forgot.status == .ok)
            #expect(try forgot.content.decode(MessageResponseDTO.self).message == "비밀번호 재설정 안내 메일을 발송했습니다.")

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
            try await verifyPasswordReset(app, emailService: emailService)
            try await verifyEmailRateLimits(app)
            try await verifyRateLimits(app)
            try await app.autoRevert()
        }
    }
    private func verifyPasswordReset(_ app: Application, emailService: MockEmailService) async throws {
        let email = UUID().uuidString + "@example.com"
        let oldPassword = String(AuthSession.randomToken().prefix(16))
        let newPassword = String(AuthSession.randomToken().prefix(16))
        let signup = try await request(app, .POST, "signup", body: ["email": email, "password": oldPassword])
        try #require(signup.status == .ok)
        let session = try signup.content.decode(SessionResponseDTO.self)
        let userID = try #require(UUID(uuidString: session.user.id))

        let forgot = try await request(app, .POST, "forgot-password", body: ["email": email])
        try #require(forgot.status == .ok)
        #expect(emailService.sentEmail == email)
        let resetURL = try #require(emailService.sentResetURL)
        let token = try #require(URLComponents(string: resetURL)?.queryItems?.first { $0.name == "token" }?.value)
        let stored = try #require(try await PasswordResetToken.query(on: app.db)
            .filter(\.$user.$id == userID).first())
        #expect(stored.tokenHash == AuthSession.hash(token))
        #expect(stored.tokenHash != token)
        #expect(try #require(stored.expiresAt) > Date())

        let reset = try await request(app, .POST, "reset-password", body: ["token": token, "newPassword": newPassword])
        try #require(reset.status == .ok)
        #expect(try await PasswordResetToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        let reused = try await request(app, .POST, "reset-password", body: ["token": token, "newPassword": oldPassword])
        #expect(reused.status == .badRequest)
        let oldLogin = try await request(app, .POST, "login", body: ["email": email, "password": oldPassword])
        #expect(oldLogin.status == .unauthorized)
        let newLogin = try await request(app, .POST, "login", body: ["email": email, "password": newPassword])
        try #require(newLogin.status == .ok)
        let revoked = try await request(app, .GET, "me", token: session.accessToken)
        #expect(revoked.status == .unauthorized)
        let revokedRefresh = try await request(app, .POST, "refresh", body: ["refreshToken": try #require(session.refreshToken)])
        #expect(revokedRefresh.status == .unauthorized)

        let forgotAgain = try await request(app, .POST, "forgot-password", body: ["email": email])
        try #require(forgotAgain.status == .ok)
        let nextURL = try #require(emailService.sentResetURL)
        let expiredToken = try #require(URLComponents(string: nextURL)?.queryItems?.first { $0.name == "token" }?.value)
        let expired = try #require(try await PasswordResetToken.query(on: app.db)
            .filter(\.$user.$id == userID).first())
        expired.expiresAt = Date().addingTimeInterval(-60)
        try await expired.update(on: app.db)
        let denied = try await request(app, .POST, "reset-password", body: ["token": expiredToken, "newPassword": oldPassword])
        #expect(denied.status == .badRequest)
        let unchangedLogin = try await request(app, .POST, "login", body: ["email": email, "password": newPassword])
        #expect(unchangedLogin.status == .ok)
    }

    private func verifyEmailRateLimits(_ app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let limiter = EmailRateLimitService()
        // Exercise every shared dimension with unrelated values for the others.
        for dimension in ["recipient", "client", "ip"] {
            try await sql.raw("DELETE FROM email_rate_limits").run()
            let limit = dimension == "recipient" ? 5 : dimension == "client" ? 10 : 20
            for index in 0...limit {
                let allowed = try await limiter.allow(
                    to: dimension == "recipient" ? " SAME@example.com " : "\(index)@example.com",
                    clientID: dimension == "client" ? "installation" : "\(index)",
                    ip: dimension == "ip" ? "192.0.2.1" : "192.0.2.\(index)",
                    action: .signUpVerification, on: app.db)
                #expect(allowed == (index < limit))
            }
            try await sql.raw("UPDATE email_rate_limits SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'").run()
            #expect(try await limiter.allow(to: "same@example.com", clientID: "installation",
                ip: "192.0.2.1", action: .signUpVerification, on: app.db))
        }
        // Action and global policies are independent of recipient/client/IP.
        for global in [false, true] {
            try await sql.raw("DELETE FROM email_rate_limits").run()
            var policy = EmailRateLimitPolicy()
            if global { policy.global = .init(limit: 2, seconds: 600) }
            else { policy.action = .init(limit: 2, seconds: 600) }
            let service = EmailRateLimitService(policy: policy)
            for index in 0..<3 {
                let allowed = try await service.allow(to: "\(index)@example.com", clientID: nil,
                    ip: "\(index)", action: global ? EmailAction(rawValue: "\(index)") : .emailChangeVerification,
                    on: app.db)
                #expect(allowed == (index < 2))
            }
        }
        try await sql.raw("DELETE FROM email_rate_limits").run()
        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await limiter.allow(to: "concurrent@example.com", clientID: "\(index)",
                        ip: "\(index)", action: .signUpVerification, on: app.db)
                }
            }
            var count = 0
            for try await result in group { if result { count += 1 } }
            return count
        }
        #expect(accepted == 5)
        let rows = try await sql.raw("SELECT bucket_key FROM email_rate_limits").all()
        for row in rows {
            let key = try row.decode(column: "bucket_key", as: String.self)
            #expect(!key.contains("@"))
            #expect(key == "global" || key.split(separator: ":").last?.count == 64)
        }
        // Existing and nonexistent accounts always return the same response, even
        // after suppression. Suppressed requests must leave the last token intact.
        for exists in [false, true] {
            try await sql.raw("DELETE FROM email_rate_limits").run()
            let email = UUID().uuidString + "@example.com"
            if exists {
                let signup = try await request(app, .POST, "signup",
                    body: ["email": email, "password": "Example123!"])
                try #require(signup.status == .ok)
            }
            var lastHash: String?
            for index in 0..<7 {
                let response = try await app.sendRequest(.POST, "auth/forgot-password",
                    beforeRequest: { req in
                        req.headers.add(name: "X-Client-ID", value: "installation")
                        try req.content.encode(["email": email])
                    })
                #expect(response.status == .ok)
                #expect(try response.content.decode(MessageResponseDTO.self).message == "비밀번호 재설정 안내 메일을 발송했습니다.")
                if exists {
                    let user = try #require(try await User.query(on: app.db).filter(\.$email == email).first())
                    let token = try #require(try await PasswordResetToken.query(on: app.db)
                        .filter(\.$user.$id == user.requireID()).first())
                    if index >= 5 { #expect(token.tokenHash == lastHash) }
                    lastHash = token.tokenHash
                }
            }
        }
        // Header-based client quota is enforced through the common sending gateway.
        try await sql.raw("DELETE FROM email_rate_limits").run()
        let transport = MockEmailService()
        let gateway = EmailService(transport: transport)
        for index in 0...10 {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.headers.add(name: "X-Client-ID", value: "shared-installation")
            let recipient = "\(index)@gateway.example"
            var prepared = false
            let allowed = try await gateway.withRequest(to: recipient, action: .emailChangeVerification, on: req) {
                prepared = true
                return .init(recipient: recipient, subject: "Verification", html: "test")
            }
            #expect(allowed == (index < 10))
            #expect(prepared == (index < 10))
        }
        #expect(transport.sentEmail == "9@gateway.example")
        // Normalization spans action types, with an additional sensitive-action window.
        try await sql.raw("DELETE FROM email_rate_limits").run()
        var sensitivePolicy = EmailRateLimitPolicy()
        sensitivePolicy.sensitiveRecipients[.passwordReset] = .init(limit: 1, seconds: 3600)
        let sensitive = EmailRateLimitService(policy: sensitivePolicy)
        #expect(try await sensitive.allow(to: " SAME@example.com ", clientID: nil,
            ip: "test", action: .passwordReset, on: app.db))
        #expect(try await !sensitive.allow(to: "same@EXAMPLE.COM", clientID: nil,
            ip: "test", action: .passwordReset, on: app.db))
        #expect(try await sensitive.allow(to: "same@example.com", clientID: nil,
            ip: "test", action: .signUpVerification, on: app.db))
        for _ in 0..<2 {
            #expect(try await sensitive.allow(to: "same@example.com", clientID: nil,
                ip: "test", action: .emailChangeVerification, on: app.db))
        }
        #expect(try await !sensitive.allow(to: "same@example.com", clientID: nil,
            ip: "test", action: .signUpVerification, on: app.db))
        // Optional client ID does not fail requests; untrusted forwarding is ignored.
        let req = Request(application: app, on: app.eventLoopGroup.next())
        req.headers.add(name: "X-Real-IP", value: "192.0.2.9")
        req.headers.add(name: "X-Forwarded-For", value: "192.0.2.8")
        #expect(EmailRateLimitService.clientIP(req, trustRailway: false) == "unknown")
        #expect(EmailRateLimitService.clientIP(req, trustRailway: true) == "192.0.2.9")
        req.headers.replaceOrAdd(name: "X-Real-IP", value: "invalid")
        #expect(EmailRateLimitService.clientIP(req, trustRailway: true) == "unknown")
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
                "Content-Type": "application/json",
                "X-Forwarded-For": "192.0.2." + String(attempt)
            ])
            // Vapor returns 422 when the declared JSON body cannot be decoded.
            #expect(response.status == (attempt <= 30 ? .unprocessableEntity : .tooManyRequests))
        }
    }

}
