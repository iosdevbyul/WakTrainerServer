@testable import WakTrainerServer
import Fluent
import SQLKit
import JWT
import Testing
import VaporTesting

extension AuthIntegrationTests {
    func verifyAPIErrorContracts(_ app: Application, emailService: MockEmailService) async throws {
        let client = SessionTestClient(app: app)
        let sql = try #require(app.db as? any SQLDatabase)
        try await client.clearLimits()
        let session = try await client.signup()
        let userID = try #require(UUID(uuidString: session.user.id))
        func check(_ response: TestingHTTPResponse, _ code: APIErrorCode) throws {
            let body = try response.content.decode(APIErrorResponseDTO.self)
            #expect(body.code == code)
            #expect(body.status == response.status.code)
            #expect(body.reason == body.message)
            #expect(body.error)
        }
        try check(try await client.request(.POST, "login", body: ["email": session.user.email, "password": "Incorrect123!"]), .invalidCredentials)
        try check(try await client.request(.POST, "signup", body: ["email": session.user.email, "password": "Example123!"]), .emailAlreadyExists)
        let invalid = try await client.request(.POST, "signup", body: ["email": "invalid", "password": "Example123!"])
        try check(invalid, .validationFailed)
        #expect(try invalid.content.decode(APIErrorResponseDTO.self).details?.first?.field == .email)
        try check(try await client.request(.GET, "me"), .authenticationRequired)
        let signingRequest = Request(application: app, on: app.eventLoopGroup.next())
        let proof = try await client.stored(session)
        let expiredJWT = try await signingRequest.jwt.sign(AccessTokenPayload(userID: userID,
            expirationDate: Date().addingTimeInterval(-60), sessionID: proof.requireID()))
        for token in [expiredJWT, session.accessToken + "invalid"] {
            let response = try await app.sendRequest(.GET, "auth/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            })
            try check(response, .accessTokenInvalidOrExpired)
        }
        let other = try await client.login(session)
        #expect(try await client.request(.POST, "logout", session: other).status == .ok)
        try check(try await client.request(.GET, "me", session: other), .sessionInvalid)
        try check(try await client.refresh(other), .refreshTokenRejected)
        try check(try await client.request(.POST, "change-password", session: session,
            body: ["currentPassword": "Incorrect123!", "newPassword": "Updated123!"]), .currentPasswordInvalid)
        try check(try await client.request(.DELETE, "sessions/invalid", session: session), .validationFailed)
        try check(try await client.request(.DELETE, "sessions/" + UUID().uuidString, session: session), .notFound)
        for (path, code) in [("verify-email", APIErrorCode.emailVerificationTokenInvalid),
                              ("reset-password", .passwordResetTokenInvalid), ("confirm-email-change", .emailChangeTokenInvalid)] {
            try check(try await client.request(.POST, path, session: session,
                body: ["token": "invalid", "newPassword": "Updated123!"]), code)
        }
        let rejected = try await client.request(.POST, "refresh", body: ["refreshToken": "invalid"])
        try check(rejected, .refreshTokenRejected)
        for _ in 0..<11 {
            _ = try await client.request(.POST, "login", body: ["email": session.user.email, "password": "Incorrect123!"])
        }
        let limited = try await client.request(.POST, "login", body: ["email": session.user.email, "password": "Incorrect123!"])
        try check(limited, .rateLimited)
        #expect(limited.headers.first(name: "Retry-After").flatMap(Int.init) != nil)
        // Audit middleware still sees typed AbortError status before global serialization.
        for event in [AuditEventType.loginFailed, .refreshRejected, .loginRateLimited] {
            let rows = try await AuditLog.query(on: app.db).filter(\.$eventType == event.rawValue).all()
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0.metadata.statusCode == (event == .loginRateLimited ? 429 : 401) })
        }
        try await client.clearLimits()

        // Uncommitted withdrawal leaves the proof visible to the initial lookup, then blocks
        // verification's user lock. Commit deletion only after observing that lock wait.
        let verificationURL = try #require(emailService.sentVerificationURL)
        let token = try #require(URLComponents(string: verificationURL)?.queryItems?.first { $0.name == "token" }?.value)
        let successesBefore = try await AuditLog.query(on: app.db)
            .filter(\.$eventType == AuditEventType.emailVerificationSucceeded.rawValue).count()
        let task = try await app.db.transaction { db in
            let tx = try #require(db as? any SQLDatabase)
            try await tx.raw("DELETE FROM users WHERE id = \(bind: userID)").run()
            let task = Task { try await client.request(.POST, "verify-email", body: ["token": token]) }
            var waiting = false
            for _ in 0..<100 {
                let rows = try await sql.raw("""
                    SELECT pid FROM pg_stat_activity WHERE datname = current_database()
                    AND wait_event_type = 'Lock' AND query LIKE 'SELECT id FROM users WHERE id =%'
                    """).all()
                if !rows.isEmpty { waiting = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(waiting, "Verification must have passed initial token lookup and be waiting for the deleted user")
            return task
        }
        let raced = try await task.value
        #expect(raced.status == .badRequest)
        try check(raced, .emailVerificationTokenInvalid)
        #expect(try await AuditLog.query(on: app.db)
            .filter(\.$eventType == AuditEventType.emailVerificationSucceeded.rawValue).count() == successesBefore)
        try await client.clearLimits()
    }
}
