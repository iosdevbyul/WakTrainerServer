import Vapor

struct HealthResponse: Content {
    let status: String
}

func routes(_ app: Application) throws {
    // Liveness only: no database query or authentication is required.
    app.get("health") { _ in
        HealthResponse(status: "ok")
    }
}
