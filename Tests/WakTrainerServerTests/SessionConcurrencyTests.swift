@testable import WakTrainerServer
import Fluent
import Testing
import VaporTesting

extension AuthIntegrationTests {
    func verifySessionRaces(_ app: Application) async throws {
        let client = SessionTestClient(app: app)
        // Different valid caller and target sessions ensure revocation remains authorized
        // regardless of whether the target refresh gets the user lock first.
        for operation in ["specific", "others", "all"] {
            try await client.clearLimits()
            let caller = try await client.signup()
            let target = try await client.login(caller)
            let targetID = try await client.stored(target).managementIdentifier().uuidString
            let method: HTTPMethod = operation == "specific" ? .DELETE : .POST
            let path = operation == "specific" ? "sessions/" + targetID : operation == "others" ? "logout-other-sessions" : "logout-all"
            async let refresh = client.refresh(target)
            async let revoke = client.request(method, path, session: caller)
            let (refreshed, revoked) = try await (refresh, revoke)
            #expect(revoked.status == .ok)
            #expect(refreshed.status == .ok || refreshed.status == .unauthorized)
            try await client.denied(target)
            if refreshed.status == .ok {
                try await client.denied(refreshed.content.decode(SessionResponseDTO.self))
            }
            if operation == "all" {
                try await client.denied(caller)
                let id = try #require(UUID(uuidString: caller.user.id))
                #expect(try await RefreshToken.query(on: app.db).filter(\.$user.$id == id).count() == 0)
            } else {
                #expect(try await client.list(caller).count == 1)
            }
        }
        // Same-caller refresh may invalidate the revocation request's Bearer token first.
        // A 401 is an explicit failure, never a successful logout leaving a live successor.
        try await client.clearLimits()
        let caller = try await client.signup()
        async let refreshed = client.refresh(caller)
        async let loggedOut = client.request(.POST, "logout-all", session: caller)
        let (refresh, logout) = try await (refreshed, loggedOut)
        if logout.status == .ok {
            try await client.denied(caller)
            if refresh.status == .ok { try await client.denied(refresh.content.decode(SessionResponseDTO.self)) }
        } else {
            #expect(logout.status == .unauthorized)
            try #require(refresh.status == .ok)
            let current = try refresh.content.decode(SessionResponseDTO.self)
            #expect(try await client.request(.POST, "logout-all", session: current).status == .ok)
            try await client.denied(current)
        }
        // Explicit revoke-first ordering: deleted proof cannot mint a replacement.
        try await client.clearLimits()
        let actor = try await client.signup()
        let target = try await client.login(actor)
        let id = try await client.stored(target).managementIdentifier().uuidString
        #expect(try await client.request(.DELETE, "sessions/" + id, session: actor).status == .ok)
        #expect(try await client.refresh(target).status == .unauthorized)
        try await client.clearLimits()
    }
}
