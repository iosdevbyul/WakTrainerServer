import Vapor
import Fluent
import JWT

struct AuthController: RouteCollection {

    private let emailService: EmailService
    private let passwordResetURLBase: String?
    private let emailChange: EmailChangeService
    private let emailVerification: EmailVerificationService

    init(emailService: EmailService = EmailService(), passwordResetURLBase: String? = nil,
         emailVerificationURLBase: String? = nil, emailChangeURLBase: String? = nil) {
        self.emailChange = .init(emailService: emailService, verificationURLBase: emailChangeURLBase)
        self.emailService = emailService
        self.passwordResetURLBase = passwordResetURLBase
        self.emailVerification = .init(emailService: emailService, verificationURLBase: emailVerificationURLBase)
    }

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("request-email-change", use: requestEmailChange)
        auth.post("confirm-email-change", use: confirmEmailChange)
        auth.get("sessions", use: sessions)
        auth.delete("sessions", ":sessionID", use: revokeSession)
        auth.post("logout-other-sessions", use: logoutOtherSessions)
        auth.post("logout-all", use: logoutAll)
        auth.post("login", use: login)
        auth.post("signup", use: signUp)
        auth.post("refresh", use: refresh)
        auth.get("me", use: me)
        auth.post("logout", use: logout)
        auth.delete("withdraw", use: withdraw)
        auth.post("forgot-password", use: forgotPassword)
        auth.post("change-password", use: changePassword)
        auth.post("reset-password", use: resetPassword)
        auth.post("verify-email", use: verifyEmail)
        auth.post("resend-verification-email", use: resendVerificationEmail)
    }

    private func validate(email: String, password: String) throws {
        guard email.utf8.count <= 254, email.contains("@"), email.contains(".") else {
            throw Abort(.badRequest, reason: "올바른 이메일 형식을 입력해주세요.")
        }
        try validate(password: password)
    }

    private func validate(password: String) throws {
        // bcrypt uses at most 72 bytes, including for multibyte characters.
        guard (7...20).contains(password.count), password.utf8.count <= 72 else {
            throw Abort(.badRequest, reason: "비밀번호는 7자 이상 20자 이하, UTF-8 기준 72바이트 이하로 입력해주세요.")
        }
    }

    @Sendable
    func login(req: Request) async throws -> SessionResponseDTO {
        try await LoginRateLimiter.checkIP(req)
        let body = try req.content.decode(AuthRequestDTO.self)
        try validate(email: body.email, password: body.password)
        try await LoginRateLimiter.checkEmail(body.email, on: req.db)
        guard let existing = try await User.query(on: req.db).filter(\.$email == body.email).first() else {
            throw Abort(.unauthorized, reason: "이메일 또는 비밀번호가 올바르지 않습니다.")
        }
        let userID = try existing.requireID()
        return try await req.db.transaction { db in
            let user = try await AuthSession.lockUser(userID, on: db)
            guard user.email == body.email,
                  try await req.password.async.verify(body.password, created: user.passwordHash) else {
                throw Abort(.unauthorized, reason: "이메일 또는 비밀번호가 올바르지 않습니다.")
            }
            return try await AuthSession.issue(for: user, request: req, on: db)
        }
    }

    @Sendable
    func signUp(req: Request) async throws -> SessionResponseDTO {
        let body = try req.content.decode(AuthRequestDTO.self)
        try validate(email: body.email, password: body.password)
        guard try await User.query(on: req.db).filter(\.$email == body.email).first() == nil else {
            throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
        }
        let passwordHash = try await req.password.async.hash(body.password)
        let session: SessionResponseDTO
        do {
            session = try await req.db.transaction { db in
                let user = User(email: body.email, passwordHash: passwordHash)
                try await user.create(on: db)
                return try await AuthSession.issue(for: user, request: req, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The UNIQUE constraint also protects concurrent signups.
            throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
        }
        await sendVerificationEmail(to: body.email, on: req)
        return session
    }

    private func sendVerificationEmail(to email: String, on req: Request) async {
        do {
            try await emailVerification.send(to: email, on: req)
        } catch {
            // Do not log addresses, URLs, raw tokens, or provider errors.
            // Delivery failure must not turn a committed signup into an apparent failure.
            req.logger.warning("Email verification delivery failed; a resend can be requested.")
        }
    }

    @Sendable
    func resendVerificationEmail(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(ResendVerificationEmailRequestDTO.self)
        guard body.email.utf8.count <= 254, body.email.contains("@"), body.email.contains(".") else {
            throw Abort(.badRequest, reason: "올바른 이메일 형식을 입력해주세요.")
        }
        await sendVerificationEmail(to: body.email, on: req)
        return .init(message: "인증이 필요한 계정이면 이메일 인증 안내를 발송했습니다.")
    }

    @Sendable
    func verifyEmail(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(VerifyEmailRequestDTO.self)
        try await emailVerification.verify(token: body.token, on: req)
        return .init(message: "이메일 인증이 완료되었습니다.")
    }

    @Sendable
    func requestEmailChange(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        _ = try await AuthSession.validate(payload, on: req.db)
        let body = try req.content.decode(RequestEmailChangeRequestDTO.self)
        // Preserve signup/login's exact email comparison and storage policy.
        guard body.newEmail.utf8.count <= 254, body.newEmail.contains("@"), body.newEmail.contains("."),
              !body.currentPassword.isEmpty, body.currentPassword.utf8.count <= 72 else {
            throw Abort(.badRequest, reason: "올바른 이메일과 현재 비밀번호를 입력해주세요.")
        }
        try await emailChange.request(newEmail: body.newEmail, currentPassword: body.currentPassword,
                                      payload: payload, on: req)
        return .init(message: "새 이메일로 이메일 변경 인증 안내를 발송했습니다.")
    }

    @Sendable
    func confirmEmailChange(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        let body = try req.content.decode(ConfirmEmailChangeRequestDTO.self)
        try await emailChange.confirm(token: body.token, payload: payload, on: req)
        return .init(message: "이메일이 변경되었습니다. 다른 세션은 로그아웃되었습니다.")
    }

    @Sendable
    func refresh(req: Request) async throws -> SessionResponseDTO {
        let body = try req.content.decode(RefreshRequestDTO.self)
        guard body.refreshToken.utf8.count == 64 else { throw Abort(.unauthorized) }
        let hash = AuthSession.hash(body.refreshToken)
        guard let existing = try await RefreshToken.query(on: req.db).filter(\.$tokenHash == hash).first() else {
            throw Abort(.unauthorized)
        }
        let userID = existing.$user.id
        return try await req.db.transaction { db in
            let user = try await AuthSession.lockUser(userID, on: db)
            guard let session = try await RefreshToken.query(on: db).filter(\.$tokenHash == hash).first(),
                  session.expiresAt > Date() else { throw Abort(.unauthorized) }
            try await session.delete(on: db)
            return try await AuthSession.issue(for: user, request: req, on: db, rotating: session)
        }
    }

    @Sendable
    func me(req: Request) async throws -> UserResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        _ = try await AuthSession.validate(payload, on: req.db)
        guard let user = try await User.find(UUID(uuidString: payload.subject.value), on: req.db) else {
            throw Abort(.unauthorized)
        }
        return .init(id: try user.requireID().uuidString, email: user.email, isEmailVerified: user.isEmailVerified)
    }

    @Sendable
    func logout(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        try await req.db.transaction { db in
            _ = try await AuthSession.lockUser(userID, on: db)
            let session = try await AuthSession.validate(payload, on: db)
            try await session.delete(on: db)
        }
        return .init(message: "Successfully logged out.")
    }

    @Sendable
    func withdraw(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        try await req.db.transaction { db in
            let user = try await AuthSession.lockUser(userID, on: db)
            _ = try await AuthSession.validate(payload, on: db)
            // The foreign key cascades deletion to every session for this user.
            try await user.delete(on: db)
        }
        return .init(message: "Account withdrawn successfully.")
    }

    @Sendable
    func changePassword(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        let body = try req.content.decode(ChangePasswordRequestDTO.self)
        try validate(password: body.newPassword)
        guard !body.currentPassword.isEmpty, body.currentPassword.utf8.count <= 72,
              body.currentPassword != body.newPassword else {
            throw Abort(.badRequest, reason: "현재 비밀번호와 다른 새 비밀번호를 입력해주세요.")
        }
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        let passwordHash = try await req.password.async.hash(body.newPassword)
        try await req.db.transaction { db in
            let user = try await AuthSession.lockUser(userID, on: db)
            _ = try await AuthSession.validate(payload, on: db)
            guard try await req.password.async.verify(body.currentPassword, created: user.passwordHash) else {
                throw Abort(.unauthorized, reason: "현재 비밀번호가 올바르지 않습니다.")
            }
            try await EmailChangeToken.query(on: db).filter(\.$user.$id == userID).delete()
            user.passwordHash = passwordHash
            try await user.update(on: db)
            try await RefreshToken.query(on: db).filter(\.$user.$id == userID).delete()
        }
        return .init(message: "Password changed successfully. Please log in again.")
    }

    @Sendable
    func forgotPassword(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(ForgotPasswordRequestDTO.self)

        guard body.email.utf8.count <= 254,
              body.email.contains("@"),
              body.email.contains(".") else {
            throw Abort(
                .badRequest,
                reason: "올바른 이메일 형식을 입력해주세요."
            )
        }

        let responseMessage = "비밀번호 재설정 안내 메일을 발송했습니다."

        var resetToken: PasswordResetToken?
        do {
            _ = try await emailService.withRequest(to: body.email, action: .passwordReset, on: req) {
                guard let user = try await User.query(on: req.db)
                    .filter(\.$email == body.email)
                    .first()
                else {
                    return nil
                }

                let userID = try user.requireID()

                let rawToken = AuthSession.randomToken()
                let tokenHash = AuthSession.hash(rawToken)
                let expiresAt = Date().addingTimeInterval(30 * 60)

                guard let resetURLBase = passwordResetURLBase ?? Environment.get("PASSWORD_RESET_URL_BASE"),
                      !resetURLBase.isEmpty else {
                    throw Abort(
                        .internalServerError,
                        reason: "PASSWORD_RESET_URL_BASE environment variable is required."
                    )
                }

                let resetURL = "\(resetURLBase)?token=\(rawToken)"

                let token: PasswordResetToken? = try await req.db.transaction { db in
                    let lockedUser = try await AuthSession.lockUser(userID, on: db)
                    guard lockedUser.email == body.email else { return nil }
                    try await PasswordResetToken.query(on: db)
                        .filter(\.$user.$id == userID).delete()
                    let token = PasswordResetToken(userID: userID, tokenHash: tokenHash, expiresAt: expiresAt)
                    try await token.create(on: db)
                    return token
                }
                guard let token else { return nil }
                resetToken = token

                return .passwordReset(to: body.email, resetURL: resetURL)
            }
        } catch {
            if let resetToken { try? await resetToken.delete(on: req.db) }
            throw error
        }

        return .init(message: responseMessage)
    }

    @Sendable
    func resetPassword(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(ResetPasswordRequestDTO.self)

        try validate(password: body.newPassword)

        guard body.token.utf8.count == 64 else {
            throw Abort(
                .badRequest,
                reason: "유효하지 않은 비밀번호 재설정 토큰입니다."
            )
        }

        let tokenHash = AuthSession.hash(body.token)

        guard let resetToken = try await PasswordResetToken.query(on: req.db)
            .filter(\.$tokenHash == tokenHash)
            .first()
        else {
            throw Abort(
                .badRequest,
                reason: "유효하지 않거나 만료된 비밀번호 재설정 토큰입니다."
            )
        }

        guard let expiresAt = resetToken.expiresAt,
              expiresAt > Date() else {
            try? await resetToken.delete(on: req.db)

            throw Abort(
                .badRequest,
                reason: "유효하지 않거나 만료된 비밀번호 재설정 토큰입니다."
            )
        }

        let userID = resetToken.$user.id
        let passwordHash = try await req.password.async.hash(body.newPassword)

        try await req.db.transaction { db in
            let user = try await AuthSession.lockUser(userID, on: db)
            guard let currentToken = try await PasswordResetToken.query(on: db)
                .filter(\.$user.$id == userID).filter(\.$tokenHash == tokenHash).first(),
                  let expiry = currentToken.expiresAt, expiry > Date() else {
                throw Abort(.badRequest, reason: "유효하지 않거나 만료된 비밀번호 재설정 토큰입니다.")
            }

            try await EmailChangeToken.query(on: db).filter(\.$user.$id == userID).delete()
            user.passwordHash = passwordHash
            try await user.update(on: db)

            try await RefreshToken.query(on: db)
                .filter(\.$user.$id == userID)
                .delete()

            try await PasswordResetToken.query(on: db)
                .filter(\.$user.$id == userID)
                .delete()
        }

        return .init(
            message: "Password reset successfully. Please log in again."
        )
    }
}
