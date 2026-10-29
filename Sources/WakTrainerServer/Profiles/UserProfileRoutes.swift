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

        try await persist(payload, userID: user.userID, on: request.db)
        return payload
    }

    /// Handles simultaneous first saves for a user. A unique constraint guarantees
    /// that only one row is created; the losing insert retries as an update.
    static func persist(_ payload: UserProfilePayload, userID: UUID, on database: any Database) async throws {
        if let existing = try await UserProfileRecord.query(on: database)
            .filter(\.$userID == userID)
            .first() {
            try await update(existing, with: payload, on: database)
            return
        }

        let record = UserProfileRecord(
            userID: userID, gender: payload.gender,
            birthDate: payload.birthDate, heightCm: payload.heightCm, weightKg: payload.weightKg
        )
        do {
            try await record.create(on: database)
        } catch {
            // Do not mask unrelated database errors if a row was not created.
            guard let existing = try await UserProfileRecord.query(on: database)
                .filter(\.$userID == userID)
                .first() else {
                throw error
            }
            try await update(existing, with: payload, on: database)
        }
    }

    private static func update(_ record: UserProfileRecord, with payload: UserProfilePayload, on database: any Database) async throws {
        record.gender = payload.gender
        record.birthDate = payload.birthDate
        record.heightCm = payload.heightCm
        record.weightKg = payload.weightKg
        try await record.update(on: database)
    }
}
