import Fluent
import Vapor
import Foundation

struct EmailVerificationService: Sendable {
    static let tokenLifetime: TimeInterval = 24 * 60 * 60
    let emailService: EmailService
    var verificationURLBase: String?

    /// Account lookup is inside the common limiter, including unknown/verified accounts.
    /// Callers return a generic message; mail failures never roll back an existing account.
    func send(to email: String, on req: Request) async throws {
        var createdTokenID: UUID?
        do {
            _ = try await emailService.withRequest(to: email, action: .signUpVerification, on: req) {
                guard let existing = try await User.query(on: req.db)
                    .filter(\.$email == email).first() else { return nil }
                let userID = try existing.requireID()
                let prepared: (UUID, EmailMessage)? = try await req.db.transaction { db in
                    let user = try await AuthSession.lockUser(userID, on: db)
                    guard user.email == email, !user.isEmailVerified else { return nil }
                    let rawToken = AuthSession.randomToken()
                    let url = try Self.verificationURL(
                        base: verificationURLBase ?? Environment.get("EMAIL_VERIFICATION_URL_BASE"),
                        token: rawToken, setting: "EMAIL_VERIFICATION_URL_BASE")
                    try await EmailVerificationToken.query(on: db).filter(\.$user.$id == userID).delete()
                    let token = EmailVerificationToken(
                        userID: userID, tokenHash: AuthSession.hash(rawToken),
                        expiresAt: Date().addingTimeInterval(Self.tokenLifetime)
                    )
                    try await token.create(on: db)
                    return (try token.requireID(), .signUpVerification(to: email, verificationURL: url))
                }
                createdTokenID = prepared?.0
                return prepared?.1
            }
        } catch {
            // Delete only this send's token, never one created by a concurrent resend.
            if let id = createdTokenID {
                try? await EmailVerificationToken.query(on: req.db).filter(\.$id == id).delete()
            }
            throw error
        }
    }

    /// Shared HTTPS link construction for email ownership proofs.
    static func verificationURL(base: String?, token: String, setting: String) throws -> String {
        guard let base, var components = URLComponents(string: base),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil else {
            throw Abort(.internalServerError, reason: "A valid HTTPS \(setting) is required.")
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(.init(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url?.absoluteString else { throw Abort(.internalServerError) }
        return url
    }

    func verify(token rawToken: String, on req: Request) async throws {
        let invalid = Abort(.badRequest, reason: "유효하지 않거나 만료된 이메일 인증 토큰입니다.")
        guard rawToken.utf8.count == 64 else { throw invalid }
        let hash = AuthSession.hash(rawToken)
        guard let existing = try await EmailVerificationToken.query(on: req.db)
            .filter(\.$tokenHash == hash).first() else { throw invalid }
        let userID = existing.$user.id
        try await req.db.transaction { db in
            let user: User
            do {
                user = try await AuthSession.lockUser(userID, on: db)
            } catch let error as Abort where error.status == .unauthorized {
                throw invalid
            }
            // Re-read under the same user lock as resend/withdraw. Only one consumer wins.
            guard let token = try await EmailVerificationToken.query(on: db)
                .filter(\.$tokenHash == hash).filter(\.$user.$id == userID).first(),
                  token.expiresAt > Date(), !user.isEmailVerified else { throw invalid }
            user.isEmailVerified = true
            try await user.update(on: db)
            try await token.delete(on: db)
            req.auditIdentity(userID)
        }
    }
}
