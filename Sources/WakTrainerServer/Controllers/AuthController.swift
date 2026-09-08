import Vapor
import Fluent
import JWT

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("login", use: login)
        auth.post("signup", use: signUp)
        auth.post("refresh", use: refresh)
        auth.get("me", use: me)
        auth.post("logout", use: logout)
        auth.delete("withdraw", use: withdraw)
        auth.post("forgot-password", use: forgotPassword)
        auth.post("change-password", use: changePassword)
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
            guard try await req.password.async.verify(body.password, created: user.passwordHash) else {
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
        do {
            return try await req.db.transaction { db in
                let user = User(email: body.email, passwordHash: passwordHash)
                try await user.create(on: db)
                return try await AuthSession.issue(for: user, request: req, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The UNIQUE constraint also protects concurrent signups.
            throw Abort(.conflict, reason: "이미 사용 중인 이메일입니다.")
        }
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
            return try await AuthSession.issue(for: user, request: req, on: db)
        }
    }

    @Sendable
    func me(req: Request) async throws -> UserResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        _ = try await AuthSession.validate(payload, on: req.db)
        guard let user = try await User.find(UUID(uuidString: payload.subject.value), on: req.db) else {
            throw Abort(.unauthorized)
        }
        return .init(id: try user.requireID().uuidString, email: user.email)
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

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == body.email)
            .first()
        else {
            return .init(message: responseMessage)
        }

        let userID = try user.requireID()

        let rawToken = AuthSession.randomToken()
        let tokenHash = AuthSession.hash(rawToken)
        let expiresAt = Date().addingTimeInterval(30 * 60)

        guard let resetURLBase = Environment.get("PASSWORD_RESET_URL_BASE"),
              !resetURLBase.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "PASSWORD_RESET_URL_BASE environment variable is required."
            )
        }

        let resetURL = "\(resetURLBase)?token=\(rawToken)"

        try await PasswordResetToken.query(on: req.db)
            .filter(\.$user.$id == userID)
            .delete()

        let resetToken = PasswordResetToken(
            userID: userID,
            tokenHash: tokenHash,
            expiresAt: expiresAt
        )

        try await resetToken.create(on: req.db)

        do {
            try await EmailService().sendPasswordResetEmail(
                to: user.email,
                resetURL: resetURL,
                on: req
            )
        } catch {
            try? await resetToken.delete(on: req.db)
            throw error
        }

        return .init(message: responseMessage)
    }
}
