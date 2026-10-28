import Fluent
import Foundation

final class UserProfileRecord: Model, @unchecked Sendable {
    static let schema = "user_profiles"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "gender")
    var gender: String

    @Field(key: "birth_date")
    var birthDate: String

    @Field(key: "height_cm")
    var heightCm: Double

    @Field(key: "weight_kg")
    var weightKg: Double

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userID: UUID, gender: String, birthDate: String, heightCm: Double, weightKg: Double) {
        self.userID = userID
        self.gender = gender
        self.birthDate = birthDate
        self.heightCm = heightCm
        self.weightKg = weightKg
    }
}
