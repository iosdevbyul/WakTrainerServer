@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

struct StubAuthenticationClient: AuthenticationClient {
    let authenticateToken: @Sendable (String) async throws -> AuthenticatedUser

    func authenticate(accessToken: String, on request: Request) async throws -> AuthenticatedUser {
        try await authenticateToken(accessToken)
    }
}

@Suite("Authenticated API routes")
struct AuthenticationRouteTests {
    @Test("Missing or malformed authorization is rejected before introspection", arguments: [
        nil, "", "Basic abc", "Bearer", "Bearer a b", "Bearer a\tb", "Bearer a,b", "Bearer a=b", "Bearer a\n"
    ] as [String?])
    func malformedAuthorization(header: String?) async throws {
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { _ in
                Issue.record("Malformed authorization must not call the authentication server")
                throw AuthenticationError.unauthorized
            })
        }) { app in
            let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                if let header { request.headers.add(name: .authorization, value: header) }
            })
            #expect(response.status == .unauthorized)
        }
    }

    @Test("The protected handler reads only the introspected identity")
    func authenticatedIdentity() async throws {
        let expected = AuthenticatedUser(userID: UUID(), sessionID: UUID())
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { token in
                let correctToken = token == "opaque-test-token"
                #expect(correctToken)
                return expected
            })
        }) { app in
            let response = try await app.sendRequest(.GET, "/v1/auth-test?userId=untrusted", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "opaque-test-token")
            })
            #expect(response.status == .ok)
            let identity = try response.content.decode(AuthTestResponse.self)
            #expect(identity.userId == expected.userID)
            #expect(identity.sessionId == expected.sessionID)
            let json = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect(Set(json.keys) == ["userId", "sessionId"])
        }
    }

    @Test("Failed introspection rejects the protected request")
    func rejectedSession() async throws {
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { _ in throw AuthenticationError.unauthorized })
        }) { app in
            let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: "invalid-test-token")
            })
            #expect(response.status == .unauthorized)
        }
    }

    @Test("Public health never calls the authentication client")
    func publicHealth() async throws {
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { _ in
                Issue.record("Health must remain independent of authentication")
                throw AuthenticationError.unavailable
            })
        }) { app in
            let response = try await app.sendRequest(.GET, "/health")
            #expect(response.status == .ok)
            #expect(try response.content.decode(HealthResponse.self).status == "ok")
        }
    }
}
