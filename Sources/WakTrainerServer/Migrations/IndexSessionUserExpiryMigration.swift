import Fluent
import SQLKit
import Vapor

/// Separate, nontransactional migration: do not block production writes for an index build.
struct IndexSessionUserExpiryMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        // An interrupted concurrent build can leave an invalid index. Repair it on retry.
        if let row = try await sql.raw("""
            SELECT indisvalid FROM pg_index
            WHERE indexrelid = to_regclass('refresh_tokens_user_expiry_idx')
            """).first(), try !row.decode(column: "indisvalid", as: Bool.self) {
            try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS refresh_tokens_user_expiry_idx").run()
        }
        try await sql.raw("""
            CREATE INDEX CONCURRENTLY IF NOT EXISTS refresh_tokens_user_expiry_idx
            ON refresh_tokens (user_id, expires_at, id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS refresh_tokens_user_expiry_idx").run()
    }
}
