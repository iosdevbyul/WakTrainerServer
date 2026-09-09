import Fluent
import Vapor

final class EmailChangeToken: Model, @unchecked Sendable {
    static let schema = "email_change_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "pending_email")
    var pendingEmail: String

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userID: UUID, pendingEmail: String, tokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.pendingEmail = pendingEmail
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}
