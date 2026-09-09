@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting
import Foundation

extension AuthIntegrationTests {
    private func changeRequest(_ app: Application, _ path: String, session: SessionResponseDTO? = nil,
                               body: [String: String] = [:]) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "auth/" + path, beforeRequest: { req in
            req.headers.add(name: "X-Client-ID", value: "email-change-installation")
            if let session { req.headers.bearerAuthorization = .init(token: session.accessToken) }
            try req.content.encode(body)
        })
    }

    private func changeToken(_ mail: MockEmailService) throws -> String {
        let url = try #require(mail.sentEmailChangeURL)
        let components = try #require(URLComponents(string: url))
        #expect(components.queryItems?.first { $0.name == "source" }?.value == "mail")
        #expect(components.queryItems?.filter { $0.name == "token" }.count == 1)
        return try #require(components.queryItems?.first { $0.name == "token" }?.value)
    }

    func verifyEmailChange(_ app: Application, emailService mail: MockEmailService) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        func clearLimits() async throws {
            try await sql.raw("DELETE FROM email_rate_limits").run()
            try await sql.raw("DELETE FROM login_rate_limits").run()
        }
        func signup() async throws -> SessionResponseDTO {
            let result = try await changeRequest(app, "signup", body: [
                "email": UUID().uuidString + "@example.com", "password": "Example123!"
            ])
            try #require(result.status == .ok)
            return try result.content.decode(SessionResponseDTO.self)
        }
        func request(_ session: SessionResponseDTO, _ email: String, password: String = "Example123!") async throws -> TestingHTTPResponse {
            try await changeRequest(app, "request-email-change", session: session,
                                    body: ["currentPassword": password, "newEmail": email])
        }
        func confirm(_ session: SessionResponseDTO, _ token: String) async throws -> TestingHTTPResponse {
            try await changeRequest(app, "confirm-email-change", session: session, body: ["token": token])
        }
        func me(_ session: SessionResponseDTO) async throws -> TestingHTTPResponse {
            try await app.sendRequest(.GET, "auth/me", headers: ["Authorization": "Bearer " + session.accessToken])
        }
        try await clearLimits()
        let owner = try await signup()
        let ownerVerificationURL = try #require(mail.sentVerificationURL)
        let ownerVerification = try #require(URLComponents(string: ownerVerificationURL)?.queryItems?.first { $0.name == "token" }?.value)
        let stranger = try await signup()
        let userID = try #require(UUID(uuidString: owner.user.id))
        // Exact case and whitespace storage is intentionally the same as signup/login.
        let newEmail = " New-" + UUID().uuidString + "@Example.com "
        let before = mail.sentCount
        #expect(try await request(owner, newEmail, password: "Wrong123!").status == .unauthorized)
        #expect(try await request(owner, owner.user.email).status == .badRequest)
        #expect(try await request(owner, stranger.user.email).status == .conflict)
        #expect(try await request(owner, "invalid").status == .badRequest)
        #expect(mail.sentCount == before)
        #expect(try await EmailChangeToken.query(on: app.db).count() == 0)
        try await clearLimits()
        #expect(try await request(owner, newEmail).status == .ok)
        #expect(mail.sentEmail == newEmail)
        let first = try changeToken(mail)
        let stored = try #require(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).first())
        #expect(first.count == 64)
        #expect(stored.tokenHash == AuthSession.hash(first))
        #expect(stored.tokenHash != first)
        #expect(stored.pendingEmail == newEmail)
        #expect(stored.createdAt != nil)
        #expect(stored.expiresAt > Date())
        #expect(stored.expiresAt <= Date().addingTimeInterval(EmailChangeService.tokenLifetime))
        #expect(try await me(owner).content.decode(UserResponseDTO.self).email == owner.user.email)
        #expect(try await User.find(userID, on: app.db)?.isEmailVerified == false)
        // Pending requests do not break login or refresh.
        let login = try await changeRequest(app, "login", body: ["email": owner.user.email, "password": "Example123!"])
        try #require(login.status == .ok)
        let secondSession = try login.content.decode(SessionResponseDTO.self)
        let refreshed = try await changeRequest(app, "refresh", body: ["refreshToken": try #require(secondSession.refreshToken)])
        try #require(refreshed.status == .ok)
        let completingSession = try refreshed.content.decode(SessionResponseDTO.self)
        #expect(completingSession.user.email == owner.user.email)
        // Confirmation may use a different valid session of the same user.
        for token in ["invalid", AuthSession.randomToken()] {
            #expect(try await confirm(completingSession, token).status == .badRequest)
        }
        #expect(try await changeRequest(app, "confirm-email-change", body: ["token": first]).status == .unauthorized)
        #expect(try await confirm(stranger, first).status == .badRequest)
        #expect(try await request(owner, newEmail).status == .ok)
        let second = try changeToken(mail)
        #expect(second != first)
        #expect(try await confirm(completingSession, first).status == .badRequest)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).count() == 1)
        let expired = try #require(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).first())
        expired.expiresAt = Date().addingTimeInterval(-1)
        try await expired.update(on: app.db)
        #expect(try await confirm(completingSession, second).status == .badRequest)
        #expect(try await request(owner, newEmail).status == .ok)
        let valid = try changeToken(mail)
        // Existing ownership/reset proofs must disappear on completion.
        #expect(try await changeRequest(app, "forgot-password", body: ["email": owner.user.email]).status == .ok)
        let resetURL = try #require(mail.sentResetURL)
        let oldReset = try #require(URLComponents(string: resetURL)?.queryItems?.first { $0.name == "token" }?.value)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == userID).count() == 1)
        async let a = confirm(completingSession, valid)
        async let b = confirm(completingSession, valid)
        let results = try await [a, b]
        #expect(results.filter { $0.status == .ok }.count == 1)
        #expect(results.filter { $0.status == .badRequest }.count == 1)
        #expect(try await confirm(completingSession, valid).status == .badRequest)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        #expect(try await PasswordResetToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        #expect(try await changeRequest(app, "verify-email", body: ["token": ownerVerification]).status == .badRequest)
        let profile = try await me(completingSession).content.decode(UserResponseDTO.self)
        #expect(profile.email == newEmail)
        #expect(profile.isEmailVerified)
        #expect(try await me(owner).status == .unauthorized)
        #expect(try await changeRequest(app, "refresh", body: ["refreshToken": try #require(owner.refreshToken)]).status == .unauthorized)
        #expect(try await confirm(owner, valid).status == .unauthorized)
        #expect(try await changeRequest(app, "reset-password", body: ["token": oldReset, "newPassword": "Updated123!"]).status == .badRequest)
        #expect(try await changeRequest(app, "login", body: ["email": owner.user.email, "password": "Example123!"]).status == .unauthorized)
        #expect(try await changeRequest(app, "login", body: ["email": newEmail, "password": "Example123!"]).status == .ok)
        let afterRefresh = try await changeRequest(app, "refresh", body: ["refreshToken": try #require(completingSession.refreshToken)])
        try #require(afterRefresh.status == .ok)
        let current = try afterRefresh.content.decode(SessionResponseDTO.self)
        #expect(current.user.email == newEmail)
        #expect(current.user.isEmailVerified)

        // Failure recovery and throttling preserve the account and only mutate allowed tokens.
        try await clearLimits()
        let nextEmail = UUID().uuidString + "@example.com"
        #expect(try await request(current, nextEmail).status == .ok)
        let beforeFailure = try changeToken(mail)
        mail.shouldFail = true
        let failed = try await request(current, nextEmail)
        mail.shouldFail = false
        #expect(failed.status == .badGateway)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        #expect(try await confirm(current, beforeFailure).status == .badRequest)
        #expect(try await me(current).content.decode(UserResponseDTO.self).email == newEmail)
        #expect(try await request(current, nextEmail).status == .ok)
        for _ in 0..<2 { #expect(try await request(current, nextEmail).status == .ok) }
        let last = try changeToken(mail)
        let sentCount = mail.sentCount
        #expect(try await request(current, nextEmail).status == .tooManyRequests)
        #expect(mail.sentCount == sentCount)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).first()?.tokenHash == AuthSession.hash(last))
        // Each limiter dimension is enforced through this endpoint before replacement/delivery.
        for key in ["global", "action:" + AuthSession.hash(EmailAction.emailChangeVerification.rawValue),
                    "client:" + AuthSession.hash("email-change-installation"),
                    "ip:" + AuthSession.hash("unknown"),
                    "recipient:" + AuthSession.hash(nextEmail.lowercased())] {
            try await sql.raw("UPDATE email_rate_limits SET attempts = 0").run()
            try await sql.raw("UPDATE email_rate_limits SET attempts = 1001 WHERE bucket_key = \(bind: key)").run()
            #expect(try await request(current, nextEmail).status == .tooManyRequests)
            #expect(mail.sentCount == sentCount)
            try await sql.raw("UPDATE email_rate_limits SET attempts = 0").run()
        }
        let deleted = try await app.sendRequest(.DELETE, "auth/withdraw", headers: ["Authorization": "Bearer " + current.accessToken])
        #expect(deleted.status == .ok)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        #expect(try await confirm(current, last).status == .unauthorized)

        // Password changes and resets invalidate pending email changes; failed attempts do not.
        for reset in [false, true] {
            try await clearLimits()
            let session = try await signup()
            let id = try #require(UUID(uuidString: session.user.id))
            #expect(try await request(session, UUID().uuidString + "@example.com").status == .ok)
            let pending = try changeToken(mail)
            if reset {
                #expect(try await changeRequest(app, "reset-password", body: ["token": AuthSession.randomToken(), "newPassword": "Updated123!"]).status == .badRequest)
                #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == id).count() == 1)
                #expect(try await changeRequest(app, "forgot-password", body: ["email": session.user.email]).status == .ok)
                let url = try #require(mail.sentResetURL)
                let token = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "token" }?.value)
                async let firstReset = changeRequest(app, "reset-password", body: ["token": token, "newPassword": "Updated123!"])
                async let secondReset = changeRequest(app, "reset-password", body: ["token": token, "newPassword": "Updated123!"])
                let resets = try await [firstReset, secondReset]
                #expect(resets.filter { $0.status == .ok }.count == 1)
                #expect(resets.filter { $0.status == .badRequest }.count == 1)
            } else {
                #expect(try await changeRequest(app, "change-password", session: session, body: ["currentPassword": "Wrong123!", "newPassword": "Updated123!"]).status == .unauthorized)
                #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == id).count() == 1)
                #expect(try await changeRequest(app, "change-password", session: session, body: ["currentPassword": "Example123!", "newPassword": "Updated123!"]).status == .ok)
            }
            #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == id).count() == 0)
            let login = try await changeRequest(app, "login", body: ["email": session.user.email, "password": "Updated123!"])
            try #require(login.status == .ok)
            let loggedIn = try login.content.decode(SessionResponseDTO.self)
            #expect(try await confirm(loggedIn, pending).status == .badRequest)
        }
        // A provider failure from an older request must not delete a newer proof.
        try await clearLimits()
        let retryUser = try await signup()
        let retryID = try #require(UUID(uuidString: retryUser.user.id))
        let gate = EmailDeliveryGate()
        mail.failNextEmailChange(after: gate)
        let delayed = Task { try await request(retryUser, UUID().uuidString + "@example.com") }
        await gate.waitUntilBlocked()
        do {
            #expect(try await request(retryUser, UUID().uuidString + "@example.com").status == .ok)
            let replacement = try changeToken(mail)
            await gate.release()
            #expect(try await delayed.value.status == .badGateway)
            #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == retryID).first()?.tokenHash == AuthSession.hash(replacement))
            #expect(try await confirm(retryUser, replacement).status == .ok)
        } catch {
            await gate.release()
            _ = try? await delayed.value
            throw error
        }
        // A signup after issuance causes a transactional conflict, leaving the account unchanged.
        try await clearLimits()
        let conflictUser = try await signup()
        let conflictEmail = UUID().uuidString + "@example.com"
        #expect(try await request(conflictUser, conflictEmail).status == .ok)
        let conflictToken = try changeToken(mail)
        #expect(try await changeRequest(app, "signup", body: ["email": conflictEmail, "password": "Example123!"]).status == .ok)
        #expect(try await confirm(conflictUser, conflictToken).status == .conflict)
        #expect(try await me(conflictUser).content.decode(UserResponseDTO.self).email == conflictUser.user.email)
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$tokenHash == AuthSession.hash(conflictToken)).count() == 1)
        // Two different users may request an unclaimed email, but only one can claim it.
        try await clearLimits()
        let userA = try await signup()
        let userB = try await signup()
        let target = UUID().uuidString + "@example.com"
        #expect(try await request(userA, target).status == .ok)
        let tokenA = try changeToken(mail)
        #expect(try await request(userB, target).status == .ok)
        let tokenB = try changeToken(mail)
        async let confirmA = confirm(userA, tokenA)
        async let confirmB = confirm(userB, tokenB)
        let claims = try await [confirmA, confirmB]
        #expect(claims.filter { $0.status == .ok }.count == 1)
        #expect(claims.filter { $0.status == .conflict }.count == 1)
        #expect(try await User.query(on: app.db).filter(\.$email == target).count() == 1)
        // Concurrent replacement leaves exactly one usable proof.
        try await clearLimits()
        let requester = try await signup()
        let requesterID = try #require(UUID(uuidString: requester.user.id))
        async let requestA = request(requester, UUID().uuidString + "@example.com")
        async let requestB = request(requester, UUID().uuidString + "@example.com")
        let requests = try await [requestA, requestB]
        #expect(requests.allSatisfy { $0.status == .ok })
        #expect(try await EmailChangeToken.query(on: app.db).filter(\.$user.$id == requesterID).count() == 1)
        try await clearLimits()
    }
}
