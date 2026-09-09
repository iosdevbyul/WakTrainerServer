import Vapor
import Fluent
import SQLKit
import JWT
import Foundation

/// Separate from application logging. Awaited, best-effort writes after business commit.
final class AuditLogService: @unchecked Sendable {
    enum IdentifierKind: String { case email, ip, client }
    private let key: String?
    private let lock = NSLock()
    private var recent: [String: Int64] = [:]
    private var inFlight = 0
    private var warnAfter = Date.distantPast
    private var retryAfter = Date.distantPast

    init(hashKey: String? = Environment.get("AUDIT_HASH_KEY")) {
        self.key = hashKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    func identifierHash(_ value: String, kind: IdentifierKind) -> String? {
        guard let key else { return nil }
        let normalized = kind == .email
            ? value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : value
        guard !normalized.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(("audit:v1:" + kind.rawValue + ":" + normalized).utf8),
                                                 using: SymmetricKey(data: Data(key.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    func record(_ event: AuditEventType, context: AuditContext, metadata: AuditMetadata, on req: Request) async {
        let now = Date()
        let ip = EmailRateLimitService.clientIP(req, trustRailway: Environment.get("EMAIL_TRUST_RAILWAY_PROXY") == "true")
        let ipHash = ip == "unknown" ? nil : identifierHash(ip, kind: .ip)
        let clients = req.headers["X-Client-ID"]
        let client = clients.count == 1 ? clients.first?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let clientHash = client.flatMap { $0.utf8.count <= 128 ? identifierHash($0, kind: .client) : nil }
        // Some events cannot know a user; never infer existence from login/password-reset lookup.
        let anonymous = event.isNoisy || event == .accountWithdrawn
        let userID = anonymous ? nil : context.userID
        let sessionID = event.isNoisy ? nil : context.sessionManagementID
        let emailHash = context.emailHash
        let source: [String]
        switch event {
        case .loginFailed, .passwordResetRequested, .emailVerificationResendRequested:
            source = [emailHash ?? "unknown", ipHash ?? "unknown"]
        case .emailRateLimited:
            source = [metadata.action?.rawValue ?? "unknown", ipHash ?? "unknown"]
        default: source = [ipHash ?? "unknown"]
        }
        // Hash only already-pseudonymous values and static event/action labels, never credentials.
        let dedupKey = event.isNoisy ? AuthSession.hash(([event.rawValue] + source).joined(separator: ":")) : nil
        let localMinute = Int64(now.timeIntervalSince1970 / 60)
        guard lock.withLock({
            guard now >= retryAfter, inFlight < 4 else { return false }
            if let dedupKey {
                if recent[dedupKey] == localMinute { return false }
                if recent.count >= 4096 { recent = recent.filter { $0.value == localMinute } }
                // Eviction does not change DB deduplication or merge different sources.
                if recent.count >= 4096 { recent.removeAll(keepingCapacity: true) }
                recent[dedupKey] = localMinute
            }
            inFlight += 1
            return true
        }) else { return }
        defer { lock.withLock { inFlight -= 1 } }
        do {
            // A quiet logger prevents SQL bindings/provider errors entering application logs.
            let quiet = Logger(label: "security.audit.database", factory: { _ in SwiftLogNoOpLogHandler() })
            guard req.application.databases.configuration(for: .audit) != nil,
                  let db = req.application.databases.database(.audit, logger: quiet, on: req.eventLoop, withTracing: false) else {
                throw Abort(.internalServerError)
            }
            let metadataJSON = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
            try await db.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw Abort(.internalServerError) }
                try await sql.raw("SET LOCAL statement_timeout = '250ms'").run()
                try await sql.raw("SET LOCAL lock_timeout = '100ms'").run()
                // Coordinate with withdrawal without waiting behind the next auth operation.
                // Deleted or currently locked users produce an unlinked event; never resurrect IDs.
                var linkedUserID: UUID?
                if let userID, try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR KEY SHARE SKIP LOCKED").first() != nil {
                    linkedUserID = userID
                }
                try await sql.raw("""
                    INSERT INTO audit_logs
                    (id, user_id, event_type, occurred_at, session_management_id,
                     email_hash, ip_hash, client_id_hash, metadata, dedup_key, minute_bucket)
                    VALUES (\(bind: UUID()), \(bind: linkedUserID), \(bind: event.rawValue), \(bind: now),
                            \(bind: sessionID), \(bind: emailHash), \(bind: ipHash), \(bind: clientHash),
                            \(bind: metadataJSON)::jsonb, \(bind: dedupKey),
                            CASE WHEN \(bind: event.isNoisy) THEN FLOOR(EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) / 60)::bigint ELSE NULL END)
                    ON CONFLICT (dedup_key, minute_bucket) DO NOTHING
                    """).run()
            }
        } catch {
            let warn = lock.withLock {
                retryAfter = Date().addingTimeInterval(5)
                guard now >= warnAfter else { return false }
                warnAfter = now.addingTimeInterval(60)
                return true
            }
            if warn { req.logger.warning("Security audit write unavailable; authentication result preserved.") }
        }
    }
}

extension DatabaseID { static let audit = DatabaseID(string: "audit") }
