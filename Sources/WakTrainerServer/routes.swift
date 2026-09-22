import Vapor

struct HealthResponse: Content {
    let status: String
}

struct AuthTestResponse: Content {
    let userId: UUID
    let sessionId: UUID
}

func routes(_ app: Application, authenticationClient: any AuthenticationClient) throws {
    // Liveness only: no database query or authentication is required.
    app.get("health") { _ in
        HealthResponse(status: "ok")
    }

    let authenticated = app.grouped("v1").grouped(SessionAuthenticator(client: authenticationClient))
    authenticated.get("auth-test") { request in
        let user = try request.auth.require(AuthenticatedUser.self)
        return AuthTestResponse(userId: user.userID, sessionId: user.sessionID)
    }
}
