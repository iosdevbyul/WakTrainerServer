import Fluent
import Vapor
import Foundation
import JWT

struct EmailChangeService: Sendable {
    static let tokenLifetime: TimeInterval = 30 * 60
    let emailService: EmailService
    var verificationURLBase: String?

    func request(newEmail: String, currentPassword: String,
                 payload: AccessTokenPayload, on req: Request) async throws {
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        var createdTokenID: UUID?
        do {
            let allowed = try await emailService.withRequest(to: newEmail, action: .emailChangeVerification, on: req) {
                let prepared = try await req.db.transaction { db in
                    let user = try await AuthSession.lockUser(userID, on: db)
                    _ = try await AuthSession.validate(payload, on: db, request: req)
                    guard try await req.password.async.verify(currentPassword, created: user.passwordHash) else {
                        throw Abort(.unauthorized, reason: "현재 비밀번호가 올바르지 않습니다.")
                    }
                    guard user.email != newEmail else {
                        throw Abort(.badRequest, reason: "현재 이메일과 다른 이메일을 입력해주세요.")
                    }
                    guard try await User.query(on: db).filter(\.$email == newEmail).first() == nil else {
                        throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
                    }
                    let rawToken = AuthSession.randomToken()
                    let url = try EmailVerificationService.verificationURL(
                        base: verificationURLBase ?? Environment.get("EMAIL_CHANGE_URL_BASE"),
                        token: rawToken, setting: "EMAIL_CHANGE_URL_BASE")
                    try await EmailChangeToken.query(on: db).filter(\.$user.$id == userID).delete()
                    let token = EmailChangeToken(userID: userID, pendingEmail: newEmail,
                        tokenHash: AuthSession.hash(rawToken),
                        expiresAt: Date().addingTimeInterval(Self.tokenLifetime))
                    try await token.create(on: db)
                    return (try token.requireID(), EmailMessage.emailChangeVerification(to: newEmail, verificationURL: url))
                }
                createdTokenID = prepared.0
                return prepared.1
            }
            guard allowed else {
                throw Abort(.tooManyRequests, reason: "잠시 후 다시 요청해주세요.")
            }
        } catch {
            // Never delete a replacement created by a concurrent request.
            if let id = createdTokenID {
                try? await EmailChangeToken.query(on: req.db).filter(\.$id == id).delete()
            }
            throw error
        }
    }

    func confirm(token rawToken: String, payload: AccessTokenPayload, on req: Request) async throws {
        let invalid = Abort(.badRequest, reason: "유효하지 않거나 만료된 이메일 변경 토큰입니다.")
        guard rawToken.utf8.count == 64 else { throw invalid }
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        let hash = AuthSession.hash(rawToken)
        do {
            try await req.db.transaction { db in
                let user = try await AuthSession.lockUser(userID, on: db)
                let session = try await AuthSession.validate(payload, on: db, request: req)
                guard let token = try await EmailChangeToken.query(on: db)
                    .filter(\.$user.$id == userID).filter(\.$tokenHash == hash).first(),
                      token.expiresAt > Date(), token.pendingEmail != user.email else { throw invalid }
                guard try await User.query(on: db).filter(\.$email == token.pendingEmail).first() == nil else {
                    throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
                }
                // users.email UNIQUE arbitrates other users' confirmations/signups.
                user.email = token.pendingEmail
                user.isEmailVerified = true
                try await user.update(on: db)
                try await token.delete(on: db)
                try await EmailVerificationToken.query(on: db).filter(\.$user.$id == userID).delete()
                try await PasswordResetToken.query(on: db).filter(\.$user.$id == userID).delete()
                try await RefreshToken.query(on: db).filter(\.$user.$id == userID)
                    .filter(\.$id != session.requireID()).delete()
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
        }
    }
}
