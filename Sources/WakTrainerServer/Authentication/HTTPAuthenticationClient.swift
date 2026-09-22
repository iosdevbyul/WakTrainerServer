import Vapor

// Fixed errors keep upstream bodies, transport diagnostics, and credentials private.
enum AuthenticationError: AbortError {
    case unauthorized
    case invalidResponse
    case unavailable

    var status: HTTPResponseStatus {
        switch self {
        case .unauthorized: .unauthorized
        case .invalidResponse: .badGateway
        case .unavailable: .serviceUnavailable
        }
    }

    var reason: String {
        switch self {
        case .unauthorized: "Authentication is required."
        case .invalidResponse: "Authentication service returned an invalid response."
        case .unavailable: "Authentication service is unavailable."
        }
    }
}

struct HTTPAuthenticationClient: AuthenticationClient {
    let configuration: AuthenticationConfiguration

    func authenticate(accessToken: String, on request: Request) async throws -> AuthenticatedUser {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: accessToken)
        headers.add(name: .accept, value: "application/json")
        let response: ClientResponse
        do {
            // Transport debug/trace output must never include authorization headers.
            let logger = Logger(label: "authentication.http", factory: { _ in SwiftLogNoOpLogHandler() })
            response = try await request.client.logging(to: logger).get(
                configuration.introspectionURL, headers: headers,
                beforeSend: { $0.timeout = .seconds(5) }
            ).get()
        } catch {
            throw AuthenticationError.unavailable
        }
        switch response.status.code {
        case 200: break
        case 401, 403: throw AuthenticationError.unauthorized
        case 429, 500...599: throw AuthenticationError.unavailable
        default: throw AuthenticationError.invalidResponse
        }
        let identity: SessionIntrospectionResponse
        do {
            identity = try response.content.decode(SessionIntrospectionResponse.self)
        } catch {
            throw AuthenticationError.invalidResponse
        }
        guard identity.active else { throw AuthenticationError.unauthorized }
        return AuthenticatedUser(userID: identity.userId, sessionID: identity.sessionId)
    }
}
