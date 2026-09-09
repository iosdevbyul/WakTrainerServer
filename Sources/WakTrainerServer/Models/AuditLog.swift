import Fluent
import Vapor

final class AuditLog: Model, @unchecked Sendable {
    static let schema = "audit_logs"
    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "user_id") var user: User?
    @Field(key: "event_type") var eventType: String
    @Field(key: "occurred_at") var occurredAt: Date
    @OptionalField(key: "session_management_id") var sessionManagementID: UUID?
    @OptionalField(key: "email_hash") var emailHash: String?
    @OptionalField(key: "ip_hash") var ipHash: String?
    @OptionalField(key: "client_id_hash") var clientIDHash: String?
    @Field(key: "metadata") var metadata: AuditMetadata
    @OptionalField(key: "dedup_key") var dedupKey: String?
    @OptionalField(key: "minute_bucket") var minuteBucket: Int64?
    init() {}
}
