import Fluent
import Foundation

/// Stores the complete, unmodified workout JSON separately for each authenticated user.
/// The client-side workout UUID is used for idempotent uploads.
final class WorkoutSessionRecord: Model, @unchecked Sendable {
    static let schema = "workout_sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "session_id")
    var sessionID: UUID

    @Field(key: "payload_json")
    var payloadJSON: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userID: UUID, sessionID: UUID, payloadJSON: String) {
        self.userID = userID
        self.sessionID = sessionID
        self.payloadJSON = payloadJSON
    }
}
