import Foundation
import Vapor

struct SessionAuthenticator: AsyncRequestAuthenticator {
    let client: any AuthenticationClient

    func authenticate(request: Request) async throws {
        guard request.headers[.authorization].count == 1,
              let bearer = request.headers.bearerAuthorization,
              bearer.token.range(of: "\\A[A-Za-z0-9._~+/\\-]+=*\\z", options: .regularExpression) != nil else {
            throw AuthenticationError.unauthorized
        }
        let user = try await client.authenticate(accessToken: bearer.token, on: request)
        request.auth.login(user)
    }
}
