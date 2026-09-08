import Vapor
import Fluent
import SQLKit

/// PostgreSQL-backed fixed windows shared by all instances using the same database.
/// Counts all attempts before authentication, independently of account existence.
enum LoginRateLimiter {
    static func checkIP(_ req: Request) async throws {
        let sql = try database(req.db)
        // Bound cleanup work and skip rows being updated by other requests.
        try await sql.raw("""
            DELETE FROM login_rate_limits WHERE bucket_key IN (
                SELECT bucket_key FROM login_rate_limits
                WHERE expires_at <= CURRENT_TIMESTAMP
                ORDER BY expires_at LIMIT 100 FOR UPDATE SKIP LOCKED
            )
            """).run()
        // Never trust client-supplied forwarding headers without a proxy trust policy.
        let ip = req.remoteAddress?.ipAddress ?? "unknown"
        try await consume(key: "ip:" + AuthSession.hash(ip), limit: 30, seconds: 60, on: req.db)
    }

    static func checkEmail(_ email: String, on db: any Database) async throws {
        // This only groups rate-limit buckets; it does not change account lookup/storage.
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try await consume(key: "email:" + AuthSession.hash(key), limit: 10, seconds: 900, on: db)
    }

    private static func database(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Login throttling requires PostgreSQL.")
        }
        return sql
    }

    static func consume(key: String, limit: Int, seconds: Int, on db: any Database) async throws {
        let sql = try database(db)
        // One atomic upsert prevents parallel requests/instances from bypassing the limit.
        // DB time avoids clock differences between application hosts.
        guard let row = try await sql.raw("""
            INSERT INTO login_rate_limits (bucket_key, attempts, expires_at)
            VALUES (\(bind: key), 1, CURRENT_TIMESTAMP + \(bind: seconds) * INTERVAL '1 second')
            ON CONFLICT (bucket_key) DO UPDATE SET
                attempts = CASE WHEN login_rate_limits.expires_at <= CURRENT_TIMESTAMP THEN 1
                    ELSE LEAST(login_rate_limits.attempts + 1, \(bind: limit + 1)) END,
                expires_at = CASE WHEN login_rate_limits.expires_at <= CURRENT_TIMESTAMP
                    THEN EXCLUDED.expires_at ELSE login_rate_limits.expires_at END
            RETURNING attempts,
                GREATEST(1, CEIL(EXTRACT(EPOCH FROM (expires_at - CURRENT_TIMESTAMP))))::int AS retry_after
            """).first() else {
            throw Abort(.internalServerError)
        }
        let attempts = try row.decode(column: "attempts", as: Int.self)
        if attempts > limit {
            let retryAfter = try row.decode(column: "retry_after", as: Int.self)
            throw Abort(.tooManyRequests, headers: ["Retry-After": String(retryAfter)],
                        reason: "로그인 요청이 너무 많습니다. 잠시 후 다시 시도해주세요.")
        }
    }
}
