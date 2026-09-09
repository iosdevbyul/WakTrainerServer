@testable import WakTrainerServer
import Fluent
import SQLKit
import Testing
import VaporTesting
import Foundation
import NIOCore

extension AuthIntegrationTests {
    func verifyAuditDeduplication(_ app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let key = "deduplication-fixture-key"
        let hasher = AuditLogService(hashKey: key)
        func req(_ ip: String) throws -> Request {
            let request = Request(application: app, remoteAddress: try .init(ipAddress: ip, port: 1234), on: app.eventLoopGroup.next())
            request.headers.add(name: "X-Client-ID", value: "fixture-client")
            return request
        }
        // Independent recorder instances exercise PostgreSQL uniqueness, not an in-memory cache.
        for event in [AuditEventType.loginFailed, .refreshRejected, .loginRateLimited, .emailRateLimited,
                      .passwordResetRequested, .emailVerificationResendRequested] {
            let email = UUID().uuidString + "@example.com"
            let context = AuditContext(emailHash: hasher.identifierHash(email, kind: .email))
            let countBefore = try await AuditLog.query(on: app.db).filter(\.$eventType == event.rawValue).count()
            for _ in 0..<2 {
                await AuditLogService(hashKey: key).record(event, context: context,
                    metadata: .init(endpoint: .login, statusCode: 429, action: .passwordReset), on: try req("192.0.2.10"))
            }
            await AuditLogService(hashKey: key).record(event, context: context,
                metadata: .init(endpoint: .login, statusCode: 429, action: .passwordReset), on: try req("192.0.2.11"))
            #expect(try await AuditLog.query(on: app.db).filter(\.$eventType == event.rawValue).count() == countBefore + 2)
        }
        let emailHash = try #require(hasher.identifierHash(UUID().uuidString + "@example.com", kind: .email))
        let context = AuditContext(emailHash: emailHash)
        // Multiple sources are separate even when they share an IP (for login failures).
        for value in [emailHash, hasher.identifierHash("other@example.com", kind: .email)] {
            await AuditLogService(hashKey: key).record(.loginFailed, context: .init(emailHash: value),
                metadata: .init(reasonCode: .invalidCredentials, endpoint: .login, statusCode: 401), on: try req("192.0.2.12"))
        }
        let ipHash = hasher.identifierHash("192.0.2.12", kind: .ip)
        #expect(try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.loginFailed.rawValue).filter(\.$ipHash == ipHash).count() == 2)
        // Email action is part of the source bucket.
        for action in [AuditMetadata.Action.passwordReset, .signUpVerification, .emailChangeVerification] {
            await AuditLogService(hashKey: key).record(.emailRateLimited, context: context,
                metadata: .init(endpoint: .forgotPassword, statusCode: 200, action: action), on: try req("192.0.2.13"))
        }
        #expect(try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.emailRateLimited.rawValue)
            .filter(\.$ipHash == hasher.identifierHash("192.0.2.13", kind: .ip)).count() == 3)
        // Concurrent instances cannot insert duplicate source-minute rows.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await AuditLogService(hashKey: key).record(.loginFailed, context: context,
                        metadata: .init(endpoint: .login, statusCode: 401), on: try req("192.0.2.14"))
                }
            }
            try await group.waitForAll()
        }
        let concurrent = try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.loginFailed.rawValue)
            .filter(\.$ipHash == hasher.identifierHash("192.0.2.14", kind: .ip)).all()
        #expect(concurrent.count == 1)
        let row = try #require(concurrent.first)
        // Expiring the stored minute permits the next bucket without a wall-clock sleep.
        try await sql.raw("UPDATE audit_logs SET minute_bucket = minute_bucket - 1 WHERE id = \(bind: row.requireID())").run()
        await AuditLogService(hashKey: key).record(.loginFailed, context: context,
            metadata: .init(endpoint: .login, statusCode: 401), on: try req("192.0.2.14"))
        #expect(try await AuditLog.query(on: app.db).filter(\.$emailHash == emailHash)
            .filter(\.$ipHash == hasher.identifierHash("192.0.2.14", kind: .ip)).count() == 2)
        let noKey = AuditLogService(hashKey: nil)
        #expect(noKey.identifierHash("example@example.com", kind: .email) == nil)
        let before = try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.logout.rawValue).count()
        await noKey.record(.logout, context: .init(), metadata: .init(endpoint: .logout, statusCode: 200), on: try req("192.0.2.15"))
        let missingKey = try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.logout.rawValue)
            .sort(\.$occurredAt, .descending).first()
        #expect(missingKey?.ipHash == nil)
        #expect(missingKey?.clientIDHash == nil)
        #expect(try await AuditLog.query(on: app.db).filter(\.$eventType == AuditEventType.logout.rawValue).count() == before + 1)
        #expect(hasher.identifierHash(" A@EXAMPLE.COM ", kind: .email) == hasher.identifierHash("a@example.com", kind: .email))
        #expect(hasher.identifierHash("same", kind: .email) != hasher.identifierHash("same", kind: .client))
        #expect(hasher.identifierHash("same", kind: .client) != AuditLogService(hashKey: "different-fixture").identifierHash("same", kind: .client))
    }
}
