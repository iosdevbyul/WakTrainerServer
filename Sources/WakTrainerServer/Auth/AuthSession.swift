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

    static func deviceName(from request: Request) -> String? {
        let values = request.headers["X-Device-Name"]
        guard values.count == 1, let value = values.first,
              value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Caller holds the user lock (or owns a newly inserted user). Bounded per-user cleanup.
    static func cleanupExpired(for userID: UUID, on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            DELETE FROM refresh_tokens WHERE id IN (
                SELECT id FROM refresh_tokens
                WHERE user_id = \(bind: userID) AND expires_at <= CURRENT_TIMESTAMP
                ORDER BY expires_at, id LIMIT 100
            )
            """).run()
    }

    static func issue(for user: User, request: Request, on database: any Database, rotating previous: RefreshToken? = nil) async throws -> SessionResponseDTO {
        let userID = try user.requireID()
        let sessionID = UUID()
        let rawToken = randomToken()
        let now = Date()
        let accessToken = try await request.jwt.sign(AccessTokenPayload(
            userID: userID,
            expirationDate: now.addingTimeInterval(accessLifetime),
            sessionID: sessionID
        ))
        let session = RefreshToken(
            id: sessionID,
            userID: userID,
            tokenHash: hash(rawToken),
            expiresAt: now.addingTimeInterval(refreshLifetime)
        )
        session.managementID = try previous?.managementIdentifier() ?? UUID()
        // Legacy rows can only supply their oldest retained row timestamp.
        if let previous {
            session.startedAt = previous.managementID == nil ? previous.createdAt : previous.startedAt
        } else {
            session.startedAt = now
        }
        session.lastRefreshedAt = previous == nil ? nil : now
        session.deviceName = previous == nil ? deviceName(from: request) : previous?.deviceName
        try await cleanupExpired(for: userID, on: database)
        try await session.create(on: database)
        return SessionResponseDTO(
            user: .init(id: userID.uuidString, email: user.email, isEmailVerified: user.isEmailVerified),
            accessToken: accessToken,
            refreshToken: rawToken
        )
    }
}
