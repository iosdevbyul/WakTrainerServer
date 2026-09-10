import Vapor
import Fluent
import JWT

extension AuthController {
    @Sendable
    func sessions(req: Request) async throws -> SessionListResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw APIError(.sessionInvalid, variant: .legacyUnauthorized) }
        return try await req.db.transaction { db in
            _ = try await AuthSession.lockUser(userID, on: db)
            _ = try await AuthSession.validate(payload, on: db, request: req)
            try await AuthSession.cleanupExpired(for: userID, on: db)
            let sessions = try await RefreshToken.query(on: db)
                .filter(\.$user.$id == userID).filter(\.$expiresAt > Date())
                .sort(\.$createdAt, .descending).sort(\.$id, .ascending).all()
            return try .init(sessions: sessions.map { session in
                .init(id: try session.managementIdentifier().uuidString,
                      createdAt: session.createdAt, startedAt: session.managementID == nil ? session.createdAt : session.startedAt,
                      expiresAt: session.expiresAt, lastRefreshedAt: session.lastRefreshedAt,
                      isCurrent: session.id == payload.sessionID, deviceName: session.deviceName)
            })
        }
    }

    @Sendable
    func revokeSession(req: Request) async throws -> MessageResponseDTO {
        let payload = try await AuthSession.payload(from: req)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw APIError(.sessionInvalid, variant: .legacyUnauthorized) }
        guard let value = req.parameters.get("sessionID"), let target = UUID(uuidString: value) else {
            throw APIError(.validationFailed, variant: .sessionID)
        }
        try await req.db.transaction { db in
            _ = try await AuthSession.lockUser(userID, on: db)
            _ = try await AuthSession.validate(payload, on: db, request: req)
            // Never resolve a target outside this user's ownership scope. Legacy rows use id.
            let query = RefreshToken.query(on: db).filter(\.$user.$id == userID)
                .group(.or) { group in
                    group.filter(\.$managementID == target)
                    group.group(.and) { legacy in
                        legacy.filter(\.$managementID == nil).filter(\.$id == target)
                    }
                }
            guard try await query.first() != nil else {
                throw APIError(.notFound, variant: .sessionNotFound)
            }
            try await query.delete()
            req.auditContext.sessionManagementID = target
        }
        return .init(message: "세션이 로그아웃되었습니다.")
    }

    @Sendable
    func logoutOtherSessions(req: Request) async throws -> MessageResponseDTO {
        try await revokeSessions(req: req, keepingCurrent: true)
        return .init(message: "다른 모든 세션이 로그아웃되었습니다.")
    }

    @Sendable
    func logoutAll(req: Request) async throws -> MessageResponseDTO {
        try await revokeSessions(req: req, keepingCurrent: false)
        return .init(message: "모든 세션이 로그아웃되었습니다.")
    }

    private func revokeSessions(req: Request, keepingCurrent: Bool) async throws {
        let payload = try await AuthSession.payload(from: req)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw APIError(.sessionInvalid, variant: .legacyUnauthorized) }
        try await req.db.transaction { db in
            _ = try await AuthSession.lockUser(userID, on: db)
            let current = try await AuthSession.validate(payload, on: db, request: req)
            let query = RefreshToken.query(on: db).filter(\.$user.$id == userID)
            if keepingCurrent { query.filter(\.$id != (try current.requireID())) }
            try await query.delete()
        }
    }
}
