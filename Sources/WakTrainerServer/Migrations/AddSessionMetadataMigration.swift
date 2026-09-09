import Fluent
import SQLKit
import Vapor

struct AddSessionMetadataMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Fail/retry pre-deploy rather than wait indefinitely behind a busy table.
            try await sql.raw("SET LOCAL lock_timeout = '5s'").run()
            try await db.schema(RefreshToken.schema)
                .field("management_id", .uuid)
                .field("started_at", .datetime)
                .field("last_refreshed_at", .datetime)
                .field("device_name", .string)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SET LOCAL lock_timeout = '5s'").run()
            try await db.schema(RefreshToken.schema)
                .deleteField("management_id").deleteField("started_at")
                .deleteField("last_refreshed_at").deleteField("device_name").update()
        }
    }
}
