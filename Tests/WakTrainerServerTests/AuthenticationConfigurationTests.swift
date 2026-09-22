@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

@Suite("Authentication configuration and contract")
struct AuthenticationConfigurationTests {
    @Test("Development defaults to the local authentication server")
    func developmentDefault() throws {
        let configuration = try AuthenticationConfiguration(environment: .development, values: { _ in nil })
        #expect(configuration.introspectionURL.string == "http://127.0.0.1:8080/auth/introspect")
    }

    @Test("Base URL supports a trailing slash and an optional path prefix", arguments: [
        "https://authentication.example", "https://authentication.example/", "https://authentication.example/prefix/"
    ])
    func configuredURL(base: String) throws {
        let configuration = try AuthenticationConfiguration(environment: .production, values: { _ in base })
        let prefix = base.contains("prefix") ? "/prefix" : ""
        #expect(configuration.introspectionURL.string == "https://authentication.example" + prefix + "/auth/introspect")
    }

    @Test("Invalid or missing production settings fail without exposing their value", arguments: [
        nil, "", " ", "authentication.example", "ftp://authentication.example", "https:///",
        "https://user:sensitive-test-value@authentication.example", "https://authentication.example?token=sensitive-test-value",
        "https://authentication.example#sensitive-test-value", "http://localhost:0", "http://localhost:65536"
    ] as [String?])
    func invalidURL(value: String?) throws {
        do {
            _ = try AuthenticationConfiguration(environment: .production, values: { _ in value })
            Issue.record("Invalid configuration must fail")
        } catch let error as Abort {
            #expect(error.reason.contains("AUTHENTICATION_SERVER_URL"))
            #expect(!error.reason.contains("sensitive-test-value"))
        }
    }

    @Test("Production bootstrap requires authentication configuration")
    func productionBootstrap() async throws {
        try await withApp { app in
            app.environment = .production
            do {
                try await configure(app, environment: { key in
                    ["DATABASE_URL": "postgres://test:test-only@localhost/test?sslmode=disable"][key]
                })
                Issue.record("Production must not boot without authentication configuration")
            } catch let error as Abort {
                #expect(error.reason == "AUTHENTICATION_SERVER_URL is required in production.")
            }
        }
    }

    @Test("Introspection identity requires UUID fields")
    func invalidIdentity() throws {
        let malformed = Data(#"{"active":true,"userId":"not-a-uuid","sessionId":"not-a-uuid"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionIntrospectionResponse.self, from: malformed) }
    }
}
