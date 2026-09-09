import Fluent
import SQLKit
import Vapor

struct AddEmailVerificationMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        // Existing accounts have not proved email ownership either.
        try await sql.raw("""
            ALTER TABLE users ADD COLUMN is_email_verified BOOLEAN NOT NULL DEFAULT FALSE
            """).run()
        try await database.schema(EmailVerificationToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EmailVerificationToken.schema).delete()
        try await database.schema(User.schema).deleteField("is_email_verified").update()
    }
}
