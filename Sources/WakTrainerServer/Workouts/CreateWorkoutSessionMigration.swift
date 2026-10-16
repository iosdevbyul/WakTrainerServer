import Fluent

struct CreateWorkoutSessionMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WorkoutSessionRecord.schema)
            .id()
            .field("user_id", .uuid, .required)
            .field("session_id", .uuid, .required)
            .field("payload_json", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "session_id", name: "uq_workout_sessions_user_session")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WorkoutSessionRecord.schema).delete()
    }
}
