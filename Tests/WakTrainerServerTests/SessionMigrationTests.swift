@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting

extension AuthIntegrationTests {
    func verifySessionMigration(_ app: Application, legacyID: UUID) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let original = try #require(try await sql.raw("SELECT token_hash FROM refresh_tokens WHERE id = \(bind: legacyID)").first())
        let hash = try original.decode(column: "token_hash", as: String.self)
        try await AddSessionMetadataMigration().prepare(on: app.db)
        try await IndexSessionUserExpiryMigration().prepare(on: app.db)
        try await IndexSessionUserExpiryMigration().prepare(on: app.db) // idempotent successful index build
        let row = try #require(try await RefreshToken.find(legacyID, on: app.db))
        #expect(row.tokenHash == hash)
        #expect(row.managementID == nil)
        #expect(row.startedAt == nil)
        #expect(row.lastRefreshedAt == nil)
        #expect(row.deviceName == nil)
        #expect(try row.managementIdentifier() == legacyID)
        let payload = AccessTokenPayload(userID: row.$user.id, expirationDate: Date().addingTimeInterval(60), sessionID: legacyID)
        #expect(try await AuthSession.validate(payload, on: app.db).id == legacyID)
        try await IndexSessionUserExpiryMigration().revert(on: app.db)
        try await AddSessionMetadataMigration().revert(on: app.db)
        let preserved = try #require(try await sql.raw("SELECT token_hash FROM refresh_tokens WHERE id = \(bind: legacyID)").first())
        #expect(try preserved.decode(column: "token_hash", as: String.self) == hash)
        let columns = try await sql.raw("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'refresh_tokens'
            AND column_name IN ('management_id', 'started_at', 'last_refreshed_at', 'device_name')
            """).all()
        #expect(columns.isEmpty)
    }
}
