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
    @Test("Concurrent first profile saves converge on one user-owned record",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "1"))
    func concurrentProfileCreation() async throws {
        try await withApp(configure: { app in
            try await configure(app)
        }) { app in
            try await app.autoMigrate()
            let userID = UUID()
            let first = UserProfilePayload(
                gender: "남성", birthDate: "2005-10-24", heightCm: 175, weightKg: 70
            )
            let second = UserProfilePayload(
                gender: "여성", birthDate: "1999-06-15", heightCm: 165, weightKg: 60
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    let payload = index.isMultiple(of: 2) ? first : second
                    group.addTask {
                        try await UserProfileRoutes.persist(payload, userID: userID, on: app.db)
                    }
                }
                try await group.waitForAll()
            }

            let records = try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == userID).all()
            #expect(records.count == 1)
            if let record = records.first {
                #expect([first.birthDate, second.birthDate].contains(record.birthDate))
                try await record.delete(on: app.db)
            }
        }
    }

    @Test("Authenticated profile HTTP requests enforce ownership and return persisted data",
          .enabled(if: Environment.get("RUN_DATABASE_TESTS") == "1"))
    func authenticatedProfileHTTP() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstToken = "profile-integration-first"
        let secondToken = "profile-integration-second"
        let first = UserProfilePayload(
            gender: "남성", birthDate: "2005-10-24", heightCm: 175, weightKg: 70
        )
        let second = UserProfilePayload(
            gender: "여성", birthDate: "1999-06-15", heightCm: 165, weightKg: 60
        )
        try await withApp(configure: { app in
            try await configure(app, authenticationClient: StubAuthenticationClient { token in
                switch token {
                case firstToken: return AuthenticatedUser(userID: firstID, sessionID: UUID())
                case secondToken: return AuthenticatedUser(userID: secondID, sessionID: UUID())
                default: throw AuthenticationError.unauthorized
                }
            })
        }) { app in
            try await app.autoMigrate()
            let unknown = try await app.sendRequest(.GET, "/v1/profile", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: firstToken)
            })
            #expect(unknown.status == .notFound)

            let unauthenticated = try await app.sendRequest(.PUT, "/v1/profile", beforeRequest: { request in
                try request.content.encode(first)
            })
            #expect(unauthenticated.status == .unauthorized)

            let savedFirst = try await app.sendRequest(.PUT, "/v1/profile", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: firstToken)
                try request.content.encode(first)
            })
            #expect(savedFirst.status == .ok)
            #expect(try savedFirst.content.decode(UserProfilePayload.self).birthDate == first.birthDate)

            let savedSecond = try await app.sendRequest(.PUT, "/v1/profile", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: secondToken)
                try request.content.encode(second)
            })
            #expect(savedSecond.status == .ok)

            let firstRead = try await app.sendRequest(.GET, "/v1/profile?userId=\(secondID)", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: firstToken)
            })
            #expect(firstRead.status == .ok)
            #expect(try firstRead.content.decode(UserProfilePayload.self).birthDate == first.birthDate)

            let secondRead = try await app.sendRequest(.GET, "/v1/profile", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: secondToken)
            })
            #expect(secondRead.status == .ok)
            #expect(try secondRead.content.decode(UserProfilePayload.self).birthDate == second.birthDate)

            let invalid = UserProfilePayload(
                gender: "남성", birthDate: "2005-02-30", heightCm: 175, weightKg: 70
            )
            let rejected = try await app.sendRequest(.PUT, "/v1/profile", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: firstToken)
                try request.content.encode(invalid)
            })
            #expect(rejected.status == .badRequest)

            let records = try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == firstID).all()
            #expect(records.count == 1)
            let otherRecords = try await UserProfileRecord.query(on: app.db)
                .filter(\.$userID == secondID).all()
            #expect(otherRecords.count == 1)
            for record in records + otherRecords {
                try await record.delete(on: app.db)
            }
        }
    }

}
