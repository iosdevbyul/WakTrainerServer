@testable import WakTrainerServer
import Foundation
import Testing
import VaporTesting

private final class CapturedAuthenticationLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var text: String { lock.withLock { entries.joined(separator: "\n") } }
}

private struct AuthenticationLogHandler: LogHandler {
    let sink: CapturedAuthenticationLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        sink.append("\(event.message) \(metadata) \(event.metadata ?? [:])")
    }
}

private enum IntrospectionScenario: String, CaseIterable, Sendable {
    case active, unauthorized, forbidden, inactive, malformedJSON, missingActive
    case invalidUserID, invalidSessionID, missingSessionID, emptyBody, wrongContentType
    case upstreamFailure, throttled, unexpectedStatus, redirect, transportFailure

    var expectedStatus: HTTPResponseStatus {
        switch self {
        case .active: .ok
        case .unauthorized, .forbidden, .inactive: .unauthorized
        case .upstreamFailure, .throttled, .transportFailure: .serviceUnavailable
        default: .badGateway
        }
    }

    func response(userID: UUID, sessionID: UUID, privateDetail: String) throws -> ClientResponse {
        var response = ClientResponse(headers: ["Content-Type": "application/json"])
        var json: [String: Any] = ["active": true, "userId": userID.uuidString, "sessionId": sessionID.uuidString]
        switch self {
        case .active: break
        case .unauthorized: response.status = .unauthorized
        case .forbidden: response.status = .forbidden
        case .inactive: json["active"] = false
        case .malformedJSON:
            response.body = .init(string: privateDetail)
            return response
        case .missingActive: json.removeValue(forKey: "active")
        case .invalidUserID: json["userId"] = privateDetail
        case .invalidSessionID: json["sessionId"] = privateDetail
        case .missingSessionID: json.removeValue(forKey: "sessionId")
        case .emptyBody: return response
        case .wrongContentType: response.headers.contentType = .plainText
        case .upstreamFailure: response.status = .internalServerError
        case .throttled: response.status = .tooManyRequests
        case .unexpectedStatus: response.status = .badRequest
        case .redirect:
            response.status = .found
            response.headers.replaceOrAdd(name: .location, value: "https://untrusted.example")
        case .transportFailure: throw NSError(domain: privateDetail, code: -1)
        }
        if response.status != .ok { json = ["internalDetail": privateDetail] }
        response.body = .init(data: try JSONSerialization.data(withJSONObject: json))
        return response
    }
}

@Suite("Authentication integration failures")
struct AuthenticationIntegrationTests {
    @Test("Configured routes authenticate only validated upstream sessions", arguments: IntrospectionScenario.allCases)
    fileprivate func upstreamBehavior(scenario: IntrospectionScenario) async throws {
        let userID = UUID()
        let sessionID = UUID()
        let token = "opaque-sensitive-test-token"
        let privateDetail = "upstream-private-detail-" + token
        let logs = CapturedAuthenticationLogs()
        try await withApp(configure: { app in
            app.logger = Logger(label: "authentication-test", factory: { _ in AuthenticationLogHandler(sink: logs) })
            app.clients.use { app in
                StubHTTPClient(eventLoop: app.eventLoopGroup.next()) { _ in
                    try scenario.response(userID: userID, sessionID: sessionID, privateDetail: privateDetail)
                }
            }
            try await configure(app, environment: { key in
                ["DATABASE_PASSWORD": "test-only", "AUTHENTICATION_SERVER_URL": "https://authentication.example"][key]
            })
        }) { app in
            let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                request.headers.bearerAuthorization = .init(token: token)
            })
            #expect(response.status == scenario.expectedStatus)
            let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            if scenario == .active {
                let user = try response.content.decode(AuthTestResponse.self)
                #expect(user.userId == userID)
                #expect(user.sessionId == sessionID)
                #expect(Set(object.keys) == ["userId", "sessionId"])
            } else {
                #expect(Set(object.keys) == ["error", "reason"])
                #expect(object["error"] as? Bool == true)
                let sanitizedErrorWasLogged = logs.text.contains("Authentication")
                #expect(sanitizedErrorWasLogged)
            }
            // Check booleans rather than printing potentially sensitive assertion operands.
            let responseLeaks = response.body.string.contains(token) || response.body.string.contains("upstream-private-detail")
            let logLeaks = logs.text.contains(token) || logs.text.contains("upstream-private-detail")
            #expect(!responseLeaks)
            #expect(!logLeaks)
            let health = try await app.sendRequest(.GET, "/health")
            #expect(health.status == .ok)
            #expect(try health.content.decode(HealthResponse.self).status == "ok")
        }
    }

    @Test("The real HTTP transport does not follow introspection redirects")
    func refusesRedirects() async throws {
        try await withApp(configure: { upstream in
            upstream.get("auth", "introspect") { request in request.redirect(to: "/redirect-target") }
            upstream.get("redirect-target") { _ -> HTTPResponseStatus in
                Issue.record("Introspection must never follow redirects")
                return .ok
            }
        }) { upstream in
            try await upstream.server.start(address: .hostname("127.0.0.1", port: 0))
            do {
                let port = try #require(upstream.http.server.shared.localAddress?.port)
                try await withApp(configure: { app in
                    try await configure(app, environment: { key in
                        ["DATABASE_PASSWORD": "test-only", "AUTHENTICATION_SERVER_URL": "http://127.0.0.1:\(port)"][key]
                    })
                }) { app in
                    let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                        request.headers.bearerAuthorization = .init(token: "redirect-test-token")
                    })
                    #expect(response.status == .badGateway)
                }
            } catch {
                await upstream.server.shutdown()
                throw error
            }
            await upstream.server.shutdown()
        }
    }

    @Test("Multiple authorization headers are rejected without introspection")
    func duplicateAuthorization() async throws {
        try await withApp(configure: { app in
            try routes(app, authenticationClient: StubAuthenticationClient { _ in
                Issue.record("Ambiguous authentication must not reach the client")
                throw AuthenticationError.unauthorized
            })
        }) { app in
            let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                request.headers.add(name: .authorization, value: "Bearer first")
                request.headers.add(name: .authorization, value: "Bearer second")
            })
            #expect(response.status == .unauthorized)
        }
    }

    @Test("Every protected request checks the current authentication state")
    func noAuthenticationCache() async throws {
        let client = ChangingAuthenticationClient()
        try await withApp(configure: { try routes($0, authenticationClient: client) }) { app in
            for expected in [HTTPResponseStatus.ok, .unauthorized] {
                let response = try await app.sendRequest(.GET, "/v1/auth-test", beforeRequest: { request in
                    request.headers.bearerAuthorization = .init(token: "same-test-token")
                })
                #expect(response.status == expected)
            }
        }
    }
}

private actor ChangingAuthenticationClient: AuthenticationClient {
    private var calls = 0
    func authenticate(accessToken: String, on request: Request) async throws -> AuthenticatedUser {
        calls += 1
        guard calls == 1 else { throw AuthenticationError.unauthorized }
        return AuthenticatedUser(userID: UUID(), sessionID: UUID())
    }
}
