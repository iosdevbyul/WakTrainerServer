@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting
import Foundation

private struct SessionErrorResponse: Content, Equatable {
    let error: Bool
    let reason: String
}

struct SessionTestClient: Sendable {
    let app: Application

    func request(_ method: HTTPMethod, _ path: String, session: SessionResponseDTO? = nil,
                 body: [String: String] = [:], device: String? = nil) async throws -> TestingHTTPResponse {
        try await app.sendRequest(method, "auth/" + path, beforeRequest: { req in
            if let session { req.headers.bearerAuthorization = .init(token: session.accessToken) }
            if let device { req.headers.add(name: "X-Device-Name", value: device) }
            if !body.isEmpty { try req.content.encode(body) }
        })
    }

    func signup(device: String? = nil) async throws -> SessionResponseDTO {
        let response = try await request(.POST, "signup", body: [
            "email": UUID().uuidString + "@example.com", "password": "Example123!"
        ], device: device)
        try #require(response.status == .ok)
        return try response.content.decode(SessionResponseDTO.self)
    }

    func login(_ session: SessionResponseDTO, device: String? = nil) async throws -> SessionResponseDTO {
        let response = try await request(.POST, "login", body: [
            "email": session.user.email, "password": "Example123!"
        ], device: device)
        try #require(response.status == .ok)
        return try response.content.decode(SessionResponseDTO.self)
    }

    func refresh(_ session: SessionResponseDTO, device: String? = nil) async throws -> TestingHTTPResponse {
        try await request(.POST, "refresh", body: ["refreshToken": try #require(session.refreshToken)], device: device)
    }

    func list(_ session: SessionResponseDTO) async throws -> [ManagedSessionResponseDTO] {
        let response = try await request(.GET, "sessions", session: session)
        try #require(response.status == .ok)
        // Assert a strict public-field allowlist, including nested objects.
        let json = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        #expect(Set(json.keys) == ["sessions"])
        let rows = try #require(json["sessions"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "createdAt", "startedAt", "expiresAt", "lastRefreshedAt", "isCurrent", "deviceName"]
        for row in rows { #expect(Set(row.keys).isSubset(of: allowed)) }
        return try response.content.decode(SessionListResponseDTO.self).sessions
    }

    func stored(_ session: SessionResponseDTO) async throws -> RefreshToken {
        let token = try #require(session.refreshToken)
        return try #require(try await RefreshToken.query(on: app.db).filter(\.$tokenHash == AuthSession.hash(token)).first())
    }

    func denied(_ session: SessionResponseDTO) async throws {
        #expect(try await request(.GET, "me", session: session).status == .unauthorized)
        #expect(try await request(.GET, "sessions", session: session).status == .unauthorized)
        #expect(try await refresh(session).status == .unauthorized)
    }

    func clearLimits() async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("DELETE FROM email_rate_limits").run()
        try await sql.raw("DELETE FROM login_rate_limits").run()
    }
}

extension AuthIntegrationTests {
    func verifySessionManagement(_ app: Application) async throws {
        let client = SessionTestClient(app: app)
        try await client.clearLimits()
        let first = try await client.signup(device: " My iPhone ")
        let second = try await client.login(first, device: "iPad")
        let stranger = try await client.signup(device: String(repeating: "x", count: 129))
        #expect(try await client.stored(stranger).deviceName == nil)
        let firstRow = try await client.stored(first)
        let secondRow = try await client.stored(second)
        let otherRow = try await client.stored(stranger)
        let firstID = try firstRow.managementIdentifier().uuidString
        let secondID = try secondRow.managementIdentifier().uuidString
        let ownerID = firstRow.$user.id
        #expect(firstRow.deviceName == "My iPhone")
        #expect(firstRow.startedAt != nil)
        #expect(firstRow.lastRefreshedAt == nil)
        #expect(firstRow.managementID != firstRow.id)
        let entries = try await client.list(first)
        #expect(entries.count == 2)
        #expect(entries.filter(\.isCurrent).map(\.id) == [firstID])
        #expect(Set(entries.map(\.id)) == [firstID, secondID])
        #expect(entries.first { $0.id == firstID }?.deviceName == "My iPhone")
        #expect(try await client.list(stranger).count == 1)
        let missing = try await client.request(.DELETE, "sessions/" + UUID().uuidString, session: first)
        let foreign = try await client.request(.DELETE, "sessions/" + otherRow.managementIdentifier().uuidString, session: first)
        #expect(missing.status == .notFound)
        #expect(foreign.status == .notFound)
        #expect(try missing.content.decode(SessionErrorResponse.self) == foreign.content.decode(SessionErrorResponse.self))
        #expect(try await client.request(.DELETE, "sessions/invalid", session: first).status == .badRequest)
        #expect(try await client.request(.GET, "me", session: stranger).status == .ok)

        // Force distinct historical times without sleeping; rotation must preserve startedAt only.
        let originalStart = Date().addingTimeInterval(-3600)
        let originalCreated = Date().addingTimeInterval(-1800)
        secondRow.startedAt = originalStart
        secondRow.createdAt = originalCreated
        try await secondRow.update(on: app.db)
        let refreshed = try await client.refresh(second, device: "do not rename on refresh")
        try #require(refreshed.status == .ok)
        let rotated = try refreshed.content.decode(SessionResponseDTO.self)
        let rotatedRow = try await client.stored(rotated)
        #expect(rotatedRow.id != secondRow.id)
        #expect(rotatedRow.tokenHash != secondRow.tokenHash)
        #expect(rotatedRow.managementID == secondRow.managementID)
        #expect(abs(try #require(rotatedRow.startedAt).timeIntervalSince(originalStart)) < 0.001)
        #expect(try #require(rotatedRow.createdAt) > originalCreated)
        #expect(try #require(rotatedRow.lastRefreshedAt) > originalCreated)
        #expect(rotatedRow.deviceName == "iPad")
        let rotatedList = try await client.list(rotated)
        #expect(rotatedList.filter(\.isCurrent).map(\.id) == [secondID])
        let currentEntry = try #require(rotatedList.first { $0.isCurrent })
        #expect(abs(try #require(currentEntry.createdAt).timeIntervalSince(try #require(rotatedRow.createdAt))) < 1)
        #expect(abs(try #require(currentEntry.startedAt).timeIntervalSince(try #require(rotatedRow.startedAt))) < 1)
        #expect(abs(try #require(currentEntry.lastRefreshedAt).timeIntervalSince(try #require(rotatedRow.lastRefreshedAt))) < 1)
        try await client.denied(second)
        // The ID obtained before refresh still revokes its successor.
        #expect(try await client.request(.DELETE, "sessions/" + secondID, session: first).status == .ok)
        try await client.denied(rotated)
        #expect(try await client.request(.DELETE, "sessions/" + secondID, session: first).status == .notFound)
        #expect(try await client.list(first).count == 1)

        let third = try await client.login(first)
        let thirdStored = try await client.stored(third)
        #expect(thirdStored.deviceName == nil)
        #expect(thirdStored.managementID != firstRow.managementID)
        #expect(try await client.request(.POST, "logout-other-sessions", session: first).status == .ok)
        try await client.denied(third)
        #expect(try await client.list(first).map(\.id) == [firstID])
        #expect(try await client.request(.GET, "me", session: stranger).status == .ok)
        // Self revocation is permitted and immediately invalidates both credentials.
        #expect(try await client.request(.DELETE, "sessions/" + firstID, session: first).status == .ok)
        try await client.denied(first)
        let allA = try await client.login(first)
        let allB = try await client.login(first)
        #expect(try await client.request(.POST, "logout-all", session: allA).status == .ok)
        try await client.denied(allA)
        try await client.denied(allB)
        #expect(try await RefreshToken.query(on: app.db).filter(\.$user.$id == ownerID).count() == 0)
        #expect(try await client.request(.GET, "me", session: stranger).status == .ok)
        try await verifyLegacySessionAndCleanup(app)
        try await client.clearLimits()
    }

    private func verifyLegacySessionAndCleanup(_ app: Application) async throws {
        let client = SessionTestClient(app: app)
        try await client.clearLimits()
        let owner = try await client.signup()
        let userID = try #require(UUID(uuidString: owner.user.id))
        let legacyID = UUID()
        let rawToken = AuthSession.randomToken()
        let legacy = RefreshToken(id: legacyID, userID: userID, tokenHash: AuthSession.hash(rawToken), expiresAt: Date().addingTimeInterval(3600))
        try await legacy.create(on: app.db)
        let legacyEntry = try #require(try await client.list(owner).first { $0.id == legacyID.uuidString })
        #expect(abs(try #require(legacyEntry.startedAt).timeIntervalSince(try #require(legacy.createdAt))) < 1)
        #expect(legacyEntry.lastRefreshedAt == nil)
        let rotated = try await client.request(.POST, "refresh", body: ["refreshToken": rawToken])
        try #require(rotated.status == .ok)
        let session = try rotated.content.decode(SessionResponseDTO.self)
        let row = try await client.stored(session)
        #expect(row.managementID == legacyID)
        #expect(row.startedAt == legacy.createdAt)
        #expect(try await client.request(.DELETE, "sessions/" + legacyID.uuidString, session: owner).status == .ok)
        try await client.denied(session)

        // Bound cleanup to 100 rows and this user. No expired rows appear in the list.
        let stranger = try await client.signup()
        let strangerID = try #require(UUID(uuidString: stranger.user.id))
        let expiredOther = RefreshToken(id: UUID(), userID: strangerID,
            tokenHash: AuthSession.hash(AuthSession.randomToken()), expiresAt: Date().addingTimeInterval(-1))
        try await expiredOther.create(on: app.db)
        let expired = (0..<105).map { _ in RefreshToken(id: UUID(), userID: userID,
            tokenHash: AuthSession.hash(AuthSession.randomToken()), expiresAt: Date().addingTimeInterval(-1)) }
        try await expired.create(on: app.db)
        #expect(try await client.list(owner).count == 1)
        #expect(try await RefreshToken.query(on: app.db).filter(\.$user.$id == userID).count() == 6)
        #expect(try await RefreshToken.find(expiredOther.requireID(), on: app.db) != nil)
        _ = try await client.login(owner)
        #expect(try await RefreshToken.query(on: app.db).filter(\.$user.$id == userID).count() == 2)
        #expect(try await RefreshToken.find(expiredOther.requireID(), on: app.db) != nil)
    }
}
