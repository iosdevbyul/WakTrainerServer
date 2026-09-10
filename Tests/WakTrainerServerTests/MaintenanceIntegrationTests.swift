@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting

extension AuthIntegrationTests {
    func verifyMaintenance(_ app: Application, emailService: MockEmailService) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let client = SessionTestClient(app: app)
        try await client.clearLimits()
        let session = try await client.signup()
        let userID = try #require(UUID(uuidString: session.user.id))
        let cutoff = Date()
        let service = DatabaseMaintenanceService()
        let quiet = Logger(label: "maintenance.test", factory: { _ in SwiftLogNoOpLogHandler() })
        // Existing data remains intact through upgrade, retry and revert.
        let migration = IndexMaintenanceExpiryMigration()
        try await migration.prepare(on: app.db)
        try await migration.prepare(on: app.db)
        for table in IndexMaintenanceExpiryMigration.tables {
            let row = try #require(try await sql.raw("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(\(bind: table + "_maintenance_expiry_idx"))").first())
            #expect(try row.decode(column: "indisvalid", as: Bool.self))
        }
        try await migration.revert(on: app.db)
        #expect(try await client.request(.GET, "me", session: session).status == .ok)
        app.migrations.add(migration)
        try await app.autoMigrate()

        // Remove only this user's pending signup proof to create unique fixtures.
        try await EmailVerificationToken.query(on: app.db).filter(\.$user.$id == userID).delete()
        for target in DatabaseMaintenanceService.Target.allCases {
            let expiredID = UUID(), activeID = UUID()
            let expiredKey = expiredID.uuidString, activeKey = activeID.uuidString
            let boundary = target == .auditLogs ? cutoff.addingTimeInterval(-90 * 86_400) : cutoff
            for (id, key, date) in [(expiredID, expiredKey, boundary.addingTimeInterval(-1)),
                                     (activeID, activeKey, boundary.addingTimeInterval(target == .auditLogs ? 0 : 3600))] {
                switch target {
                case .loginRateLimits, .emailRateLimits:
                    try await sql.raw("INSERT INTO \(ident: target.rawValue) (bucket_key, attempts, expires_at) VALUES (\(bind: key), 1, \(bind: date))").run()
                case .auditLogs:
                    // Include both linked and null-user history, with strict retention boundary.
                    for linked in [false, true] {
                        try await sql.raw("INSERT INTO audit_logs (id, user_id, event_type, occurred_at, metadata) VALUES (\(bind: linked ? UUID() : id), \(bind: linked ? userID : nil), 'loginSucceeded', \(bind: date), '{}')").run()
                    }
                default:
                    // Verification/change have unique user relationships, so use another user per proof.
                    let owner = UUID()
                    try await sql.raw("INSERT INTO users (id,email,password_hash) VALUES (\(bind: owner), \(bind: owner.uuidString + "@example.com"), 'fixture')").run()
                    if target == .emailChange {
                        try await sql.raw("INSERT INTO email_change_tokens (id,user_id,pending_email,token_hash,expires_at) VALUES (\(bind: id),\(bind: owner),'pending@example.com',\(bind: id.uuidString),\(bind: date))").run()
                    } else {
                        try await sql.raw("INSERT INTO \(ident: target.rawValue) (id,user_id,token_hash,expires_at) VALUES (\(bind: id),\(bind: owner),\(bind: id.uuidString),\(bind: date))").run()
                    }
                }
            }
            _ = try await service.deleteBatch(target, on: app.db, cutoff: cutoff)
            if target.key == "id" {
                #expect(try await sql.raw("SELECT id FROM \(ident: target.rawValue) WHERE id = \(bind: expiredID)").first() == nil)
                #expect(try await sql.raw("SELECT id FROM \(ident: target.rawValue) WHERE id = \(bind: activeID)").first() != nil)
            } else {
                #expect(try await sql.raw("SELECT bucket_key FROM \(ident: target.rawValue) WHERE bucket_key = \(bind: expiredKey)").first() == nil)
                #expect(try await sql.raw("SELECT bucket_key FROM \(ident: target.rawValue) WHERE bucket_key = \(bind: activeKey)").first() != nil)
            }
        }
        #expect(try await sql.raw("SELECT id FROM audit_logs WHERE occurred_at < \(bind: cutoff.addingTimeInterval(-90 * 86_400))").first() == nil)

        // Bounded execution, no OFFSET, concurrent workers count disjoint deleted rows.
        try await client.clearLimits()
        try await sql.raw("INSERT INTO login_rate_limits SELECT 'maintenance-' || n::text, 1, \(bind: cutoff.addingTimeInterval(-1)) FROM generate_series(1, 23) n").run()
        let small = DatabaseMaintenanceService(policy: .init(batchSize: 5, maxBatches: 2))
        let bounded = await small.run(on: app.db, cutoff: cutoff, logger: quiet)
        #expect(bounded.succeeded)
        #expect(bounded.deleted[.loginRateLimits] == 10)
        #expect(bounded.capped.contains(.loginRateLimits))
        async let first = service.run(on: app.db, cutoff: cutoff, logger: quiet)
        async let second = service.run(on: app.db, cutoff: cutoff, logger: quiet)
        let (a, b) = await (first, second)
        #expect(a.succeeded && b.succeeded)
        #expect((a.deleted[.loginRateLimits] ?? 0) + (b.deleted[.loginRateLimits] ?? 0) == 13)

        // A real refresh overlaps cleanup. Its live proof and newly rotated proof survive.
        async let cleaning = service.run(on: app.db, cutoff: cutoff, logger: quiet)
        async let refreshing = client.refresh(session)
        let (cleaned, response) = try await (cleaning, refreshing)
        #expect(cleaned.succeeded)
        try #require(response.status == .ok)
        let rotated = try response.content.decode(SessionResponseDTO.self)
        #expect(try await client.request(.GET, "me", session: rotated).status == .ok)
        _ = try await service.deleteBatch(.sessions, on: app.db, cutoff: cutoff)
        #expect(try await client.request(.GET, "me", session: rotated).status == .ok)
        #expect(try await client.stored(rotated).expiresAt > cutoff)

        // Hold uncommitted updates while cleanup AND real auth finish before releasing locks.
        // Awaiting inside the transaction makes the ordering deterministic, not a timing guess.
        for target in [DatabaseMaintenanceService.Target.loginRateLimits, .emailRateLimits] {
            let key = "maintenance-lock-" + UUID().uuidString
            try await sql.raw("INSERT INTO \(ident: target.rawValue) VALUES (\(bind: key),1,\(bind: cutoff.addingTimeInterval(-1)))").run()
            try await app.db.transaction { tx in
                let locked = try #require(tx as? any SQLDatabase)
                try await locked.raw("UPDATE \(ident: target.rawValue) SET expires_at = \(bind: cutoff.addingTimeInterval(3600)) WHERE bucket_key = \(bind: key)").run()
                #expect(try await service.deleteBatch(target, on: app.db, cutoff: cutoff) == 0)
                #expect(try await client.request(.GET, "me", session: rotated).status == .ok)
            }
            #expect(try await service.deleteBatch(target, on: app.db, cutoff: cutoff) == 0)
            #expect(try await sql.raw("SELECT bucket_key FROM \(ident: target.rawValue) WHERE bucket_key = \(bind: key)").first() != nil)
        }
        // A maintenance-style candidate lock must not block the existing refresh lazy cleanup.
        let expired = RefreshToken(id: UUID(), userID: userID,
            tokenHash: AuthSession.hash(AuthSession.randomToken()), expiresAt: cutoff.addingTimeInterval(-1))
        try await expired.create(on: app.db)
        let successor = try await app.db.transaction { tx in
            let locked = try #require(tx as? any SQLDatabase)
            _ = try await locked.raw("SELECT id FROM refresh_tokens WHERE id = \(bind: expired.requireID()) FOR UPDATE SKIP LOCKED").all()
            async let cleanup = service.run(on: app.db, cutoff: cutoff, logger: quiet)
            async let response = client.refresh(rotated)
            let (result, refreshed) = try await (cleanup, response)
            #expect(result.succeeded)
            try #require(refreshed.status == .ok)
            return try refreshed.content.decode(SessionResponseDTO.self)
        }
        #expect(try await RefreshToken.find(expired.requireID(), on: app.db) != nil)
        _ = try await service.deleteBatch(.sessions, on: app.db, cutoff: cutoff)
        #expect(try await RefreshToken.find(expired.requireID(), on: app.db) == nil)
        #expect(try await client.request(.GET, "me", session: successor).status == .ok)

        // Real verification and email-change confirmations run alongside global cleanup.
        try await client.clearLimits()
        let verifying = try await client.signup()
        let verificationURL = try #require(emailService.sentVerificationURL)
        let proof = try #require(URLComponents(string: verificationURL)?.queryItems?.first { $0.name == "token" }?.value)
        async let verificationCleanup = service.run(on: app.db, cutoff: cutoff, logger: quiet)
        async let confirmation = client.request(.POST, "verify-email", body: ["token": proof])
        let (verificationResult, verified) = try await (verificationCleanup, confirmation)
        #expect(verificationResult.succeeded)
        #expect(verified.status == .ok)
        #expect(try await client.request(.POST, "request-email-change", session: verifying,
            body: ["currentPassword": "Example123!", "newEmail": UUID().uuidString + "@example.com"]).status == .ok)
        let changeURL = try #require(emailService.sentEmailChangeURL)
        let changeProof = try #require(URLComponents(string: changeURL)?.queryItems?.first { $0.name == "token" }?.value)
        async let changeCleanup = service.run(on: app.db, cutoff: cutoff, logger: quiet)
        async let change = client.request(.POST, "confirm-email-change", session: verifying, body: ["token": changeProof])
        let (changeResult, changed) = try await (changeCleanup, change)
        #expect(changeResult.succeeded)
        #expect(changed.status == .ok)
        #expect(try await client.request(.GET, "me", session: verifying).status == .ok)

        // A table lock times out only its target; later cleanup still commits.
        try await sql.raw("INSERT INTO email_rate_limits VALUES ('maintenance-after-failure',1,\(bind: cutoff.addingTimeInterval(-1)))").run()
        try await app.db.transaction { tx in
            let locked = try #require(tx as? any SQLDatabase)
            try await locked.raw("LOCK TABLE login_rate_limits IN ACCESS EXCLUSIVE MODE").run()
            let result = await service.run(on: app.db, cutoff: cutoff, logger: quiet)
            #expect(result.failed == [.loginRateLimits])
            #expect(!result.succeeded)
            #expect(result.deleted[.emailRateLimits] == 1)
            #expect(try await client.request(.GET, "me", session: successor).status == .ok)
        }
        // A fixed cutoff does not expand eligibility as wall time advances.
        let futureKey = "maintenance-fixed-cutoff"
        try await sql.raw("INSERT INTO login_rate_limits VALUES (\(bind: futureKey),1,\(bind: cutoff.addingTimeInterval(0.001)))").run()
        #expect(try await service.deleteBatch(.loginRateLimits, on: app.db, cutoff: cutoff) == 0)
        try await client.clearLimits()
    }
}
