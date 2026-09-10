import Fluent
import SQLKit
import Vapor

/// Must run outside a transaction. Concurrent builds preserve production writes.
struct IndexMaintenanceExpiryMigration: AsyncMigration {
    static let tables = ["refresh_tokens", "password_reset_tokens", "email_verification_tokens", "email_change_tokens"]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        for table in Self.tables {
            let name = table + "_maintenance_expiry_idx"
            if let row = try await sql.raw("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(\(bind: name))").first(),
               try !row.decode(column: "indisvalid", as: Bool.self) {
                try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS \(ident: name)").run()
            }
            try await sql.raw("CREATE INDEX CONCURRENTLY IF NOT EXISTS \(ident: name) ON \(ident: table) (expires_at, id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        for table in Self.tables.reversed() {
            try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS \(ident: table + "_maintenance_expiry_idx")").run()
        }
    }
}
