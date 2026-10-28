@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

@Suite("User profile API")
struct UserProfileRouteTests {
    @Test("Profile routes reject unauthenticated requests")
    func requiresAuthentication() async throws {
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { _ in
                Issue.record("Missing token must not reach introspection")
                throw AuthenticationError.unauthorized
            })
        }) { app in
            for method in [HTTPMethod.GET, .PUT] {
                let response = try await app.sendRequest(method, "/v1/profile")
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("Profile validation rejects invalid values")
    func rejectsInvalidProfile() throws {
        let valid = UserProfilePayload(
            gender: "남성", birthDate: "2005-10-24", heightCm: 175, weightKg: 70
        )
        try valid.validate()
        for input in [
            UserProfilePayload(gender: "unknown", birthDate: "2005-10-24", heightCm: 175, weightKg: 70),
            UserProfilePayload(gender: "남성", birthDate: "2005-02-30", heightCm: 175, weightKg: 70),
            UserProfilePayload(gender: "남성", birthDate: "2005-10-24", heightCm: -1, weightKg: 70)
        ] {
            #expect(throws: Error.self) { try input.validate() }
        }
    }
}
