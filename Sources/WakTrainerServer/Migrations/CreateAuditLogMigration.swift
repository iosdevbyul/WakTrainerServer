import Fluent
import SQLKit
import Vapor

struct CreateAuditLogMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SET LOCAL lock_timeout = '5s'").run()
            try await sql.raw("""
                CREATE TABLE audit_logs (
                    id UUID PRIMARY KEY,
                    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
                    event_type TEXT NOT NULL,
                    occurred_at TIMESTAMPTZ NOT NULL,
                    session_management_id UUID,
                    email_hash VARCHAR(64), ip_hash VARCHAR(64), client_id_hash VARCHAR(64),
                    metadata JSONB NOT NULL,
                    dedup_key VARCHAR(64), minute_bucket BIGINT,
                    UNIQUE (dedup_key, minute_bucket)
                )
                """).run()
            // New, empty table: ordinary index creation does not block existing auth tables.
            try await sql.raw("CREATE INDEX audit_logs_occurred_idx ON audit_logs (occurred_at)").run()
            try await sql.raw("CREATE INDEX audit_logs_user_occurred_idx ON audit_logs (user_id, occurred_at)").run()
            try await sql.raw("CREATE INDEX audit_logs_event_occurred_idx ON audit_logs (event_type, occurred_at)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AuditLog.schema).delete()
    }
}
