import Foundation
import Vapor

struct AuthenticatedUser: Authenticatable, Sendable {
    let userID: UUID
    let sessionID: UUID
}

struct SessionIntrospectionResponse: Content {
    let active: Bool
    let userId: UUID
    let sessionId: UUID
}

protocol AuthenticationClient: Sendable {
    func authenticate(accessToken: String, on request: Request) async throws -> AuthenticatedUser
}
