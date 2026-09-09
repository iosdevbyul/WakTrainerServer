@testable import WakTrainerServer
import Testing
import VaporTesting

@Suite("Session metadata")
struct SessionMetadataTests {
    @Test func optionalDeviceName() async throws {
        try await withApp(configure: { _ in }) { app in
            let req = Request(application: app, on: app.eventLoopGroup.next())
            #expect(AuthSession.deviceName(from: req) == nil)
            for invalid in ["", "   ", String(repeating: "x", count: 129), "phone\nname", "phone\u{0000}", "phone\tname"] {
                req.headers.replaceOrAdd(name: "X-Device-Name", value: invalid)
                #expect(AuthSession.deviceName(from: req) == nil)
            }
            req.headers.replaceOrAdd(name: "X-Device-Name", value: " My iPhone ")
            #expect(AuthSession.deviceName(from: req) == "My iPhone")
            req.headers.add(name: "X-Device-Name", value: "duplicate")
            #expect(AuthSession.deviceName(from: req) == nil)
        }
    }
}
