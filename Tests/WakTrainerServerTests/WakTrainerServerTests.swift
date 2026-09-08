@testable import WakTrainerServer
import VaporTesting
import Testing

@Suite("App Tests")
struct WakTrainerServerTests {
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }
    
    @Test("Test Change Password Route")
    func changePassword() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(
                .POST,
                "auth/change-password",
                beforeRequest: { req in
                    req.headers.contentType = .json

                    try req.content.encode([
                        "currentPassword": "old-password",
                        "newPassword": "new-password"
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Password changed successfully."))
                }
            )
        }
    }
}
