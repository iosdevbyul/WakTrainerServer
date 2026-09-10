@testable import WakTrainerServer
import VaporTesting
import Testing

@Suite("App Tests")
struct WakTrainerServerTests {
    @Test("Public route and protected routes without authentication")
    func routesWithoutAuthentication() async throws {
        try await withApp(configure: { app in APIErrorMiddleware.install(on: app); try routes(app) }) { app in
            let hello = try await app.sendRequest(.GET, "hello")
            #expect(hello.status == .ok)
            #expect(hello.body.string == "Hello, world!")
            for (method, path) in [(HTTPMethod.GET, "me"), (.POST, "logout"), (.DELETE, "withdraw"), (.POST, "change-password"), (.POST, "request-email-change"), (.POST, "confirm-email-change"), (.GET, "sessions"), (.DELETE, "sessions/" + UUID().uuidString), (.POST, "logout-other-sessions"), (.POST, "logout-all")] {
                let response = try await app.sendRequest(method, "auth/" + path)
                #expect(response.status == .unauthorized)
            }
            let forgot = try await app.sendRequest(.POST, "auth/forgot-password", beforeRequest: { req in
                // Invalid input is rejected before accessing the database.
                try req.content.encode(ForgotPasswordRequestDTO(email: "invalid-email"))
            })
            #expect(forgot.status == .badRequest)
        }
    }
}
