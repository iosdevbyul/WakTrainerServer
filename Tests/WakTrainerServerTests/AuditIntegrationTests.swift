@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting
import Foundation

extension AuthIntegrationTests {
    func verifyAuditLogging(_ app: Application, emailService: MockEmailService) async throws {
        let client = SessionTestClient(app: app)
        try await client.clearLimits()
        let events = try await AuditLog.query(on: app.db).all()
        let types = Set(events.map(\.eventType))
        // All prior regression scenarios run through the real audit middleware.
        for event in [AuditEventType.signUpSucceeded, .loginSucceeded, .loginFailed, .refreshSucceeded,
                      .refreshRejected, .logout, .logoutOtherSessions, .logoutAll, .sessionRevoked,
                      .passwordChanged, .passwordResetRequested, .passwordResetSucceeded,
                      .emailVerificationSucceeded, .emailVerificationResendRequested,
                      .emailChangeRequested, .emailChangeSucceeded, .accountWithdrawn,
                      .loginRateLimited, .emailRateLimited] {
            #expect(types.contains(event.rawValue))
        }
        for event in events where event.eventType == AuditEventType.loginFailed.rawValue {
            #expect(event.$user.id == nil)
            #expect(event.metadata.reasonCode == .invalidCredentials)
        }
        let user = try await client.signup(device: "never-audit-this-device")
        let id = try #require(UUID(uuidString: user.user.id))
        let rawRefresh = try #require(user.refreshToken)
        let row = try await client.stored(user)
        let success = try #require(try await AuditLog.query(on: app.db)
            .filter(\.$user.$id == id).filter(\.$eventType == AuditEventType.signUpSucceeded.rawValue).first())
        #expect(success.sessionManagementID == row.managementID)
        let freshEmail = UUID().uuidString + "@example.com"
        let wrong = ["email": freshEmail, "password": "Wrong123!"]
        for _ in 0..<2 { #expect(try await client.request(.POST, "login", body: wrong).status == .unauthorized) }
        let hash = AuditLogService(hashKey: "audit-integration-fixture-key").identifierHash(freshEmail, kind: .email)
        let failures = try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.loginFailed.rawValue)
            .filter(\.$emailHash == hash).all()
        #expect(failures.count == 1)
        #expect(failures.first?.$user.id == nil)
        let knownWrong = try await client.request(.POST, "login", body: ["email": user.user.email, "password": "Wrong123!"])
        #expect(knownWrong.status == .unauthorized)
        let knownHash = AuditLogService(hashKey: "audit-integration-fixture-key").identifierHash(user.user.email, kind: .email)
        let knownFailure = try #require(try await AuditLog.query(on: app.db)
            .filter(\.$eventType == AuditEventType.loginFailed.rawValue).filter(\.$emailHash == knownHash).first())
        #expect(knownFailure.$user.id == nil)
        #expect(knownFailure.metadata.reasonCode == failures.first?.metadata.reasonCode)

        // Business rollback after password mutation was attempted must never emit success.
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("""
            CREATE FUNCTION audit_test_reject_user_update() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'audit test business rollback'; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER audit_test_user_rollback BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION audit_test_reject_user_update()").run()
        do {
            let failed = try await client.request(.POST, "change-password", session: user,
                body: ["currentPassword": "Example123!", "newPassword": "Updated123!"])
            #expect(failed.status == .internalServerError)
            #expect(try await AuditLog.query(on: app.db).filter(\.$user.$id == id)
                .filter(\.$eventType == AuditEventType.passwordChanged.rawValue).count() == 0)
        } catch {
            try await sql.raw("DROP TRIGGER audit_test_user_rollback ON users").run()
            try await sql.raw("DROP FUNCTION audit_test_reject_user_update()").run()
            throw error
        }
        try await sql.raw("DROP TRIGGER audit_test_user_rollback ON users").run()
        try await sql.raw("DROP FUNCTION audit_test_reject_user_update()").run()
        #expect(try await client.request(.GET, "me", session: user).status == .ok)
        _ = try await client.login(user)

        let mailTokens = [emailService.sentResetURL, emailService.sentVerificationURL, emailService.sentEmailChangeURL]
            .compactMap { $0 }.compactMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "token" }?.value }
        // A busy user must not block audit writes or trigger the failure cooldown.
        let recorder = AuditLogService(hashKey: "audit-integration-fixture-key")
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let marker = UUID()
        try await app.db.transaction { db in
            _ = try await AuthSession.lockUser(id, on: db)
            await recorder.record(.logout, context: .init(userID: id, sessionManagementID: marker),
                metadata: .init(endpoint: .logout, statusCode: 200), on: req)
        }
        let unlinked = try #require(try await AuditLog.query(on: app.db).filter(\.$sessionManagementID == marker).first())
        #expect(unlinked.$user.id == nil)
        // Compare complete serialized DB rows, not just metadata keys.
        let serialized = try await sql.raw("SELECT row_to_json(audit_logs)::text AS document FROM audit_logs").all()
        for value in serialized {
            let document = try value.decode(column: "document", as: String.self)
            for forbidden in [user.user.email, freshEmail, "Example123!", "Wrong123!", "Updated123!",
                              user.accessToken, rawRefresh, row.tokenHash, "never-audit-this-device",
                              "audit-integration-fixture-key", "accessToken", "refreshToken", "passwordHash", "token_hash"] + mailTokens {
                #expect(!document.contains(forbidden))
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
            let metadata = try #require(object["metadata"] as? [String: Any])
            #expect(Set(metadata.keys).isSubset(of: ["reasonCode", "endpoint", "statusCode", "action"]))
        }
        // SET NULL retains rows without retaining the account FK after withdrawal.
        let auditID = try success.requireID()
        #expect(try await client.request(.DELETE, "withdraw", session: user).status == .ok)
        let retained = try #require(try await AuditLog.find(auditID, on: app.db))
        #expect(retained.$user.id == nil)
        let withdrawn = try #require(try await AuditLog.query(on: app.db)
            .filter(\.$eventType == AuditEventType.accountWithdrawn.rawValue)
            .filter(\.$sessionManagementID == row.managementID).first())
        #expect(withdrawn.$user.id == nil)
        try await verifyAuditDeduplication(app)
        try await verifyAuditFailure(app)
    }

    private func verifyAuditFailure(_ app: Application) async throws {
        let client = SessionTestClient(app: app)
        try await client.clearLimits()
        let sql = try #require(app.db as? any SQLDatabase)
        let owner = try await client.signup()
        let before = try await AuditLog.query(on: app.db).count()
        try await sql.raw("""
            CREATE FUNCTION audit_test_reject_insert() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'audit test storage unavailable'; END $$
            """).run()
        try await sql.raw("CREATE TRIGGER audit_test_failure BEFORE INSERT ON audit_logs FOR EACH ROW EXECUTE FUNCTION audit_test_reject_insert()").run()
        do {
            let login = try await client.login(owner)
            #expect(try await client.request(.POST, "logout", session: login).status == .ok)
            try await client.denied(login)
            #expect(try await AuditLog.query(on: app.db).count() == before)
            #expect(try await client.request(.POST, "change-password", session: owner,
                body: ["currentPassword": "Example123!", "newPassword": "Updated123!"]).status == .ok)
        } catch {
            try await sql.raw("DROP TRIGGER audit_test_failure ON audit_logs").run()
            try await sql.raw("DROP FUNCTION audit_test_reject_insert()").run()
            throw error
        }
        try await sql.raw("DROP TRIGGER audit_test_failure ON audit_logs").run()
        try await sql.raw("DROP FUNCTION audit_test_reject_insert()").run()
        // A fresh recorder proves recovery without waiting for the route recorder's cooldown.
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await AuditLogService(hashKey: nil).record(.logoutAll, context: .init(),
            metadata: .init(endpoint: .logoutAll, statusCode: 200), on: req)
        #expect(try await AuditLog.query(on: app.db).count() == before + 1)
    }
}
