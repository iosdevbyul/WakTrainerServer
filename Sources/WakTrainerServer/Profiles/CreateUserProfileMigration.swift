import Fluent

struct CreateUserProfileMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserProfileRecord.schema)
            .id()
            .field("user_id", .uuid, .required)
            .field("gender", .string, .required)
            .field("birth_date", .string, .required)
            .field("height_cm", .double, .required)
            .field("weight_kg", .double, .required)
            .field("updated_at", .datetime)
            .unique(on: "user_id", name: "uq_user_profiles_user")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserProfileRecord.schema).delete()
    }
}
