@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting
import Foundation

extension AuthIntegrationTests {
    private func verificationRequest(_ app: Application, _ path: String,
                                     body: [String: String]) async throws -> TestingHTTPResponse {
        try await app.sendRequest(.POST, "auth/" + path, beforeRequest: { req in
            req.headers.add(name: "X-Client-ID", value: "verification-test-installation")
            try req.content.encode(body)
        })
    }

    private func verificationToken(_ emailService: MockEmailService) throws -> String {
        let url = try #require(emailService.sentVerificationURL)
        return try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "token" }?.value)
    }

    func verifyEmailVerification(_ app: Application, emailService: MockEmailService) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("DELETE FROM email_rate_limits").run()
        try await sql.raw("DELETE FROM login_rate_limits").run()
        let email = UUID().uuidString + "@example.com"
        let credentials = ["email": email, "password": "Example123!"]
        let signup = try await verificationRequest(app, "signup", body: credentials)
        try #require(signup.status == .ok)
        let session = try signup.content.decode(SessionResponseDTO.self)
        #expect(!session.user.isEmailVerified)
        let userID = try #require(UUID(uuidString: session.user.id))
        let firstToken = try verificationToken(emailService)
        #expect(firstToken.utf8.count == 64)
        let stored = try #require(try await EmailVerificationToken.query(on: app.db)
            .filter(\.$user.$id == userID).first())
        #expect(stored.tokenHash == AuthSession.hash(firstToken))
        #expect(stored.tokenHash != firstToken)
        #expect(stored.expiresAt > Date())
        #expect(stored.expiresAt <= Date().addingTimeInterval(EmailVerificationService.tokenLifetime))
        #expect(try await User.find(userID, on: app.db)?.isEmailVerified == false)

        // Unverified login and refresh remain available, with unchanged session issuance.
        let login = try await verificationRequest(app, "login", body: credentials)
        try #require(login.status == .ok)
        let loginSession = try login.content.decode(SessionResponseDTO.self)
        #expect(!loginSession.user.isEmailVerified)
        let refresh = try await verificationRequest(app, "refresh",
            body: ["refreshToken": try #require(loginSession.refreshToken)])
        try #require(refresh.status == .ok)
        #expect(try refresh.content.decode(SessionResponseDTO.self).user.isEmailVerified == false)
        let duplicate = try await verificationRequest(app, "signup", body: credentials)
        #expect(duplicate.status == .conflict)

        for invalid in ["short", AuthSession.randomToken()] {
            let response = try await verificationRequest(app, "verify-email", body: ["token": invalid])
            #expect(response.status == .badRequest)
        }
        let resend = try await verificationRequest(app, "resend-verification-email", body: ["email": email])
        try #require(resend.status == .ok)
        let secondToken = try verificationToken(emailService)
        #expect(secondToken != firstToken)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == userID).count() == 1)
        let replaced = try await verificationRequest(app, "verify-email", body: ["token": firstToken])
        #expect(replaced.status == .badRequest)

        let expired = try #require(try await EmailVerificationToken.query(on: app.db)
            .filter(\.$user.$id == userID).first())
        expired.expiresAt = Date().addingTimeInterval(-1)
        try await expired.update(on: app.db)
        let expiryResponse = try await verificationRequest(app, "verify-email", body: ["token": secondToken])
        #expect(expiryResponse.status == .badRequest)
        #expect(try await User.find(userID, on: app.db)?.isEmailVerified == false)

        let resendAfterExpiry = try await verificationRequest(app, "resend-verification-email", body: ["email": email])
        try #require(resendAfterExpiry.status == .ok)
        let valid = try verificationToken(emailService)
        async let attemptA = verificationRequest(app, "verify-email", body: ["token": valid])
        async let attemptB = verificationRequest(app, "verify-email", body: ["token": valid])
        let attempts = try await [attemptA, attemptB]
        #expect(attempts.filter { $0.status == .ok }.count == 1)
        #expect(attempts.filter { $0.status == .badRequest }.count == 1)
        #expect(try await User.find(userID, on: app.db)?.isEmailVerified == true)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == userID).count() == 0)
        let reused = try await verificationRequest(app, "verify-email", body: ["token": valid])
        #expect(reused.status == .badRequest)
        let me = try await app.sendRequest(.GET, "auth/me",
            headers: ["Authorization": "Bearer " + session.accessToken])
        try #require(me.status == .ok)
        #expect(try me.content.decode(UserResponseDTO.self).isEmailVerified)
        let verifiedLogin = try await verificationRequest(app, "login", body: credentials)
        #expect(try verifiedLogin.content.decode(SessionResponseDTO.self).user.isEmailVerified)

        let before = emailService.sentCount
        let already = try await verificationRequest(app, "resend-verification-email", body: ["email": email])
        let unknown = try await verificationRequest(app, "resend-verification-email",
            body: ["email": UUID().uuidString + "@example.com"])
        #expect(already.status == .ok)
        #expect(unknown.status == .ok)
        #expect(try already.content.decode(MessageResponseDTO.self).message == unknown.content.decode(MessageResponseDTO.self).message)
        #expect(emailService.sentCount == before)
        let invalidEmail = try await verificationRequest(app, "resend-verification-email", body: ["email": "invalid"])
        #expect(invalidEmail.status == .badRequest)

        // Signup and resend share the same recipient quota. Suppression leaves the token intact.
        try await sql.raw("DELETE FROM email_rate_limits").run()
        let limitedEmail = UUID().uuidString + "@example.com"
        let limitedSignup = try await verificationRequest(app, "signup",
            body: ["email": limitedEmail, "password": "Example123!"])
        try #require(limitedSignup.status == .ok)
        let limitedSession = try limitedSignup.content.decode(SessionResponseDTO.self)
        let limitedID = try #require(UUID(uuidString: limitedSession.user.id))
        let initialCount = emailService.sentCount
        for _ in 0..<4 {
            let response = try await verificationRequest(app, "resend-verification-email", body: ["email": limitedEmail])
            #expect(response.status == .ok)
        }
        #expect(emailService.sentCount == initialCount + 4)
        let lastToken = try verificationToken(emailService)
        for _ in 0..<2 {
            let blocked = try await verificationRequest(app, "resend-verification-email", body: ["email": limitedEmail])
            #expect(blocked.status == .ok)
            #expect(try blocked.content.decode(MessageResponseDTO.self).message == unknown.content.decode(MessageResponseDTO.self).message)
        }
        #expect(emailService.sentCount == initialCount + 4)
        #expect(try await EmailVerificationToken.query(on: app.db)
            .filter(\.$user.$id == limitedID).first()?.tokenHash == AuthSession.hash(lastToken))
        // A different email action cannot bypass the shared recipient quota.
        let resetBlocked = try await verificationRequest(app, "forgot-password", body: ["email": limitedEmail])
        #expect(resetBlocked.status == .ok)
        #expect(emailService.sentCount == initialCount + 4)
        try await sql.raw("UPDATE email_rate_limits SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'").run()
        let allowedAgain = try await verificationRequest(app, "resend-verification-email", body: ["email": limitedEmail])
        #expect(allowedAgain.status == .ok)
        #expect(emailService.sentCount == initialCount + 5)
        let deletedToken = try verificationToken(emailService)
        let withdraw = try await app.sendRequest(.DELETE, "auth/withdraw",
            headers: ["Authorization": "Bearer " + limitedSession.accessToken])
        #expect(withdraw.status == .ok)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == limitedID).count() == 0)
        let deleted = try await verificationRequest(app, "verify-email", body: ["token": deletedToken])
        #expect(deleted.status == .badRequest)

        // Provider failures keep signup usable and permit recovery through resend.
        try await sql.raw("DELETE FROM email_rate_limits").run()
        let failureEmail = UUID().uuidString + "@example.com"
        emailService.shouldFail = true
        defer { emailService.shouldFail = false }
        let failureSignup = try await verificationRequest(app, "signup",
            body: ["email": failureEmail, "password": "Example123!"])
        try #require(failureSignup.status == .ok)
        let failureSession = try failureSignup.content.decode(SessionResponseDTO.self)
        let failureID = try #require(UUID(uuidString: failureSession.user.id))
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == failureID).count() == 0)
        let failedResend = try await verificationRequest(app, "resend-verification-email", body: ["email": failureEmail])
        #expect(failedResend.status == .ok)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == failureID).count() == 0)
        emailService.shouldFail = false
        let recovered = try await verificationRequest(app, "resend-verification-email", body: ["email": failureEmail])
        #expect(recovered.status == .ok)
        #expect(try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == failureID).count() == 1)
        let failureMe = try await app.sendRequest(.GET, "auth/me",
            headers: ["Authorization": "Bearer " + failureSession.accessToken])
        #expect(failureMe.status == .ok)
    }
}
