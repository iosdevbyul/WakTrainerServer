@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

struct StubHTTPClient: Client {
    let eventLoop: any EventLoop
    let respond: @Sendable (ClientRequest) throws -> ClientResponse

    func delegating(to eventLoop: any EventLoop) -> any Client {
        Self(eventLoop: eventLoop, respond: respond)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        do { return eventLoop.makeSucceededFuture(try respond(request)) }
        catch { return eventLoop.makeFailedFuture(error) }
    }
}

@Suite("HTTP authentication client")
struct HTTPAuthenticationClientTests {
    @Test("Introspection forwards the original token only in the authorization header")
    func validSession() async throws {
        let userID = UUID()
        let sessionID = UUID()
        let token = "opaque-test-access-token"
        try await withApp { app in
            app.clients.use { app in
                StubHTTPClient(eventLoop: app.eventLoopGroup.next()) { outgoing in
                    #expect(outgoing.method == .GET)
                    let correctURL = outgoing.url.string == "https://authentication.example/auth/introspect"
                    let correctAuthorization = outgoing.headers.bearerAuthorization?.token == token
                    #expect(correctURL)
                    #expect(correctAuthorization)
                    #expect(outgoing.body == nil)
                    #expect(Set(outgoing.headers.map { $0.name.lowercased() }) == ["authorization", "accept"])
                    #expect(outgoing.timeout == .seconds(5))
                    var response = ClientResponse()
                    try response.content.encode(SessionIntrospectionResponse(active: true, userId: userID, sessionId: sessionID))
                    return response
                }
            }
            let client = HTTPAuthenticationClient(configuration: try .init(environment: .testing, values: { _ in "https://authentication.example" }))
            let user = try await client.authenticate(accessToken: token, on: Request(application: app, on: app.eventLoopGroup.next()))
            #expect(user.userID == userID)
            #expect(user.sessionID == sessionID)
        }
    }

    @Test("Upstream authentication errors are unauthorized", arguments: [401, 403])
    func unauthorized(code: UInt) async throws {
        try await withApp { app in
            app.clients.use { app in
                StubHTTPClient(eventLoop: app.eventLoopGroup.next()) { _ in
                    ClientResponse(status: .init(statusCode: Int(code)), body: .init(string: "private upstream detail"))
                }
            }
            let client = HTTPAuthenticationClient(configuration: try .init(environment: .testing, values: { _ in nil }))
            await #expect(throws: AuthenticationError.unauthorized) {
                try await client.authenticate(accessToken: "invalid-test-token", on: Request(application: app, on: app.eventLoopGroup.next()))
            }
        }
    }
}
