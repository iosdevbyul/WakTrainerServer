import Vapor
import Fluent
import JWT
import SQLKit

enum AuthSession {
    static let accessLifetime: TimeInterval = 15 * 60
    static let refreshLifetime: TimeInterval = 30 * 24 * 60 * 60

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    // Serialize session mutations per user, including concurrent refresh requests.
    static func lockUser(_ id: UUID, on database: any Database) async throws -> User {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Authentication requires a SQL database.")
        }
        try await sql.raw("SELECT id FROM users WHERE id = \(bind: id) FOR UPDATE").run()
        guard let user = try await User.find(id, on: database) else {
            throw Abort(.unauthorized)
        }
        return user
    }

    static func payload(from req: Request) async throws -> AccessTokenPayload {
        do {
            let payload = try await req.jwt.verify(as: AccessTokenPayload.self)
            guard UUID(uuidString: payload.subject.value) != nil, payload.sessionID != nil else {
                throw Abort(.unauthorized)
            }
            return payload
        } catch {
            throw Abort(.unauthorized, reason: "유효한 인증 토큰이 필요합니다.")
        }
    }

    static func validate(_ payload: AccessTokenPayload, on database: any Database) async throws -> RefreshToken {
        guard let sessionID = payload.sessionID,
              let userID = UUID(uuidString: payload.subject.value),
              let session = try await RefreshToken.find(sessionID, on: database),
              session.$user.id == userID,
              session.expiresAt > Date() else {
            throw Abort(.unauthorized, reason: "만료되었거나 폐기된 세션입니다.")
        }
        return session
    }

    static func issue(for user: User, request: Request, on database: any Database) async throws -> SessionResponseDTO {
        let userID = try user.requireID()
        let sessionID = UUID()
        let rawToken = randomToken()
        let now = Date()
        let accessToken = try await request.jwt.sign(AccessTokenPayload(
            userID: userID,
            expirationDate: now.addingTimeInterval(accessLifetime),
            sessionID: sessionID
        ))
        try await RefreshToken(
            id: sessionID,
            userID: userID,
            tokenHash: hash(rawToken),
            expiresAt: now.addingTimeInterval(refreshLifetime)
        ).create(on: database)
        return SessionResponseDTO(
            user: .init(id: userID.uuidString, email: user.email),
            accessToken: accessToken,
            refreshToken: rawToken
        )
    }
}
