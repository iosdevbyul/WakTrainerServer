@testable import WakTrainerServer
import Foundation
import JWT
import Testing
import VaporTesting

@Suite("Access Token Tests")
struct AccessTokenTests {
    @Test("Signs and verifies an access token with a 15-minute expiration")
    func signAndVerify() async throws {
        try await withApp(configure: { app in
            // Generate an isolated signing key for this test only.
            await app.jwt.keys.add(
                hmac: .init(from: UUID().uuidString + UUID().uuidString),
                digestAlgorithm: .sha256
            )
        }) { app in
            let request = Request(application: app, on: app.eventLoopGroup.next())
            let userID = UUID()
            let expirationDate = Date().addingTimeInterval(15 * 60)
            let payload = AccessTokenPayload(userID: userID, expirationDate: expirationDate)

            let token = try await request.jwt.sign(payload)
            #expect(token.hasPrefix("eyJ"))
            #expect(token.split(separator: ".").count == 3)

            let verified = try await request.jwt.verify(token, as: AccessTokenPayload.self)
            #expect(verified.subject.value == userID.uuidString)
            #expect(abs(verified.expiration.value.timeIntervalSince(expirationDate)) < 1)

            let expiredToken = try await request.jwt.sign(AccessTokenPayload(
                userID: userID,
                expirationDate: Date().addingTimeInterval(-60)
            ))
            await #expect(throws: (any Error).self) {
                try await request.jwt.verify(expiredToken, as: AccessTokenPayload.self)
            }
        }
    }
}
