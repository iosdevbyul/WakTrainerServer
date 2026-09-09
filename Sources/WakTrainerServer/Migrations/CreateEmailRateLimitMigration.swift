import Fluent
import SQLKit
import Vapor

struct CreateEmailRateLimitMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("email_rate_limits")
            .field("bucket_key", .string, .identifier(auto: false))
            .field("attempts", .int, .required)
            .field("expires_at", .datetime, .required)
            .create()
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("CREATE INDEX email_rate_limits_expiry_idx ON email_rate_limits (expires_at)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("email_rate_limits").delete()
    }
}
