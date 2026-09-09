import Fluent

struct AddEmailChangeMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Additive: no rewrite/backfill or index build on the existing users table.
        try await database.schema(EmailChangeToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("pending_email", .string, .required)
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id")
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EmailChangeToken.schema).delete()
    }
}
