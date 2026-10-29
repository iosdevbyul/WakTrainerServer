@testable import WakTrainerServer
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Workout sessions PostgreSQL integration", .serialized)
struct WorkoutSessionDatabaseIntegrationTests {
    @Test("Persist the complete payload, isolate users, and reject duplicate session IDs",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "1"))
    func workoutPersistence() async throws {
        try await withApp(configure: { app in
            try await configure(app)
        }) { app in
            try await app.autoMigrate()

            let firstUser = UUID()
            let secondUser = UUID()
            let sharedSession = UUID()
            let uniqueSession = UUID()
            let rawPayload = """
                {"id":"\(sharedSession)","workout":{"workoutID":"running"},"health":{"samples":[{"value":123}]},"route":[{"latitude":37.5,"longitude":127.1}]}
                """

            let first = WorkoutSessionRecord(
                userID: firstUser, sessionID: sharedSession, payloadJSON: rawPayload
            )
            try await first.create(on: app.db)
            let second = WorkoutSessionRecord(
                userID: secondUser, sessionID: sharedSession, payloadJSON: rawPayload
            )
            try await second.create(on: app.db)
            let third = WorkoutSessionRecord(
                userID: firstUser, sessionID: uniqueSession, payloadJSON: "{}"
            )
            try await third.create(on: app.db)

            let firstUserRecords = try await WorkoutSessionRecord.query(on: app.db)
                .filter(\.$userID == firstUser).all()
            let secondUserRecords = try await WorkoutSessionRecord.query(on: app.db)
                .filter(\.$userID == secondUser).all()

            #expect(Set(firstUserRecords.map(\.sessionID)) == [sharedSession, uniqueSession])
            #expect(secondUserRecords.count == 1)
            #expect(secondUserRecords.first?.sessionID == sharedSession)
            #expect(firstUserRecords.first(where: { $0.sessionID == sharedSession })?.payloadJSON == rawPayload)

            let duplicate = WorkoutSessionRecord(
                userID: firstUser, sessionID: sharedSession, payloadJSON: rawPayload
            )
            await #expect(throws: (any Error).self) {
                try await duplicate.create(on: app.db)
            }

            try await first.delete(on: app.db)
            try await second.delete(on: app.db)
            try await third.delete(on: app.db)
        }
    }

    @Test("Persist profiles, isolate users, update records, and enforce unique user IDs",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "1"))
    func profilePersistence() async throws {
        try await withApp(configure: { app in
            try await configure(app)
        }) { app in
            try await app.autoMigrate()

            let firstID = UUID()
            let secondID = UUID()
            let first = UserProfileRecord(
                userID: firstID, gender: "남성", birthDate: "2005-10-24",
                heightCm: 175, weightKg: 70
            )
            let second = UserProfileRecord(
                userID: secondID, gender: "여성", birthDate: "1999-06-15",
                heightCm: 165, weightKg: 60
            )
            try await first.create(on: app.db)
            try await second.create(on: app.db)
            let firstRead = try #require(try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == firstID).first())
            let secondRead = try #require(try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == secondID).first())
            #expect(firstRead.birthDate == "2005-10-24")
            #expect(secondRead.birthDate == "1999-06-15")
            #expect(firstRead.gender == "남성")
            #expect(secondRead.gender == "여성")

            firstRead.weightKg = 72
            try await firstRead.update(on: app.db)
            let updated = try #require(try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == firstID).first())
            #expect(updated.weightKg == 72)
            let untouched = try #require(try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == secondID).first())
            #expect(untouched.weightKg == 60)

            let duplicate = UserProfileRecord(
                userID: firstID, gender: "기타", birthDate: "2000-01-01",
                heightCm: 170, weightKg: 65
            )
            await #expect(throws: (any Error).self) {
                try await duplicate.create(on: app.db)
            }

            try await first.delete(on: app.db)
            try await second.delete(on: app.db)
        }
    }
}
