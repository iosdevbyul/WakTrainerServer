import Fluent
import Foundation
import Vapor

struct WorkoutSessionMetadata: Content {
    let id: UUID
    let createdAt: Date?
    let updatedAt: Date?
}

struct WorkoutUploadResponse: Content {
    let id: UUID
    let created: Bool
}

enum WorkoutSessionRoutes {
    static func register(_ routes: RoutesBuilder) {
        routes.on(.PUT, "workouts", ":sessionID", body: .collect(maxSize: "25mb"), use: upload)
        routes.get("workouts", use: list)
        routes.get("workouts", ":sessionID", use: detail)
    }

    private static func sessionID(_ request: Request) throws -> UUID {
        guard let value = request.parameters.get("sessionID"),
              let uuid = UUID(uuidString: value) else {
            throw Abort(.badRequest, reason: "Invalid workout session ID.")
        }
        return uuid
    }

    private static func upload(_ request: Request) async throws -> WorkoutUploadResponse {
        let user = try request.auth.require(AuthenticatedUser.self)
        let id = try sessionID(request)
        guard let bytes = request.body.data,
              bytes.readableBytes > 0,
              bytes.readableBytes <= 25_000_000 else {
            throw Abort(.payloadTooLarge, reason: "Workout payload is empty or too large.")
        }
        let payload = Data(bytes.readableBytesView)
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let payloadID = object["id"] as? String,
              UUID(uuidString: payloadID) == id,
              object["workout"] is [String: Any],
              object["timing"] is [String: Any],
              object["exerciseRecords"] is [Any],
              object["health"] is [String: Any],
              object["route"] is [Any],
              let json = String(data: payload, encoding: .utf8) else {
            throw Abort(.badRequest, reason: "Invalid workout session payload.")
        }

        if let existing = try await WorkoutSessionRecord.query(on: request.db)
            .filter(\\.$userID == user.userID)
            .filter(\\.$sessionID == id)
            .first() {
            guard existing.payloadJSON == json else {
                throw Abort(.conflict, reason: "Workout session ID already exists with different content.")
            }
            return WorkoutUploadResponse(id: id, created: false)
        }

        let record = WorkoutSessionRecord(userID: user.userID, sessionID: id, payloadJSON: json)
        try await record.create(on: request.db)
        return WorkoutUploadResponse(id: id, created: true)
    }

    private static func list(_ request: Request) async throws -> [WorkoutSessionMetadata] {
        let user = try request.auth.require(AuthenticatedUser.self)
        let records = try await WorkoutSessionRecord.query(on: request.db)
            .filter(\\.$userID == user.userID)
            .sort(\\.$createdAt, .descending)
            .limit(100)
            .all()
        return records.map {
            WorkoutSessionMetadata(id: $0.sessionID, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }

    private static func detail(_ request: Request) async throws -> Response {
        let user = try request.auth.require(AuthenticatedUser.self)
        let id = try sessionID(request)
        guard let record = try await WorkoutSessionRecord.query(on: request.db)
            .filter(\\.$userID == user.userID)
            .filter(\\.$sessionID == id)
            .first() else {
            throw Abort(.notFound)
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(string: record.payloadJSON))
    }
}
