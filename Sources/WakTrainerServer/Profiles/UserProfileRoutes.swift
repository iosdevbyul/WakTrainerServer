import Fluent
import Foundation
import Vapor

/// Date-only strings avoid time-zone shifts of a person's date of birth.
struct UserProfilePayload: Content {
    let gender: String
    let birthDate: String
    let heightCm: Double
    let weightKg: Double

    func validate() throws {
        guard ["남성", "여성", "기타"].contains(gender),
              birthDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = Self.dateFormatter.date(from: birthDate),
              Self.dateFormatter.string(from: date) == birthDate,
              date <= Date(),
              heightCm.isFinite, (50...300).contains(heightCm),
              weightKg.isFinite, (2...500).contains(weightKg) else {
            throw Abort(.badRequest, reason: "Invalid profile fields.")
        }
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

enum UserProfileRoutes {
    static func register(_ routes: RoutesBuilder) {
        routes.get("profile", use: getProfile)
        routes.put("profile", use: putProfile)
    }

    private static func getProfile(_ request: Request) async throws -> UserProfilePayload {
        let user = try request.auth.require(AuthenticatedUser.self)
        guard let record = try await UserProfileRecord.query(on: request.db)
            .filter(\.$userID == user.userID)
            .first() else {
            throw Abort(.notFound, reason: "Profile not found.")
        }
        return UserProfilePayload(
            gender: record.gender, birthDate: record.birthDate,
            heightCm: record.heightCm, weightKg: record.weightKg
        )
    }

    private static func putProfile(_ request: Request) async throws -> UserProfilePayload {
        let user = try request.auth.require(AuthenticatedUser.self)
        let payload = try request.content.decode(UserProfilePayload.self)
        try payload.validate()

        if let existing = try await UserProfileRecord.query(on: request.db)
            .filter(\.$userID == user.userID)
            .first() {
            existing.gender = payload.gender
            existing.birthDate = payload.birthDate
            existing.heightCm = payload.heightCm
            existing.weightKg = payload.weightKg
            try await existing.update(on: request.db)
        } else {
            let record = UserProfileRecord(
                userID: user.userID, gender: payload.gender,
                birthDate: payload.birthDate,
                heightCm: payload.heightCm, weightKg: payload.weightKg
            )
            try await record.create(on: request.db)
        }
        return payload
    }
}
