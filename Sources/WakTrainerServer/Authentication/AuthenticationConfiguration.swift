import Foundation
import Vapor

struct AuthenticationConfiguration: Sendable, StorageKey {
    typealias Value = AuthenticationConfiguration
    let introspectionURL: URI

    init(environment: Environment, values: (String) -> String?) throws {
        let value = values("AUTHENTICATION_SERVER_URL")
            ?? (environment == .production ? nil : "http://127.0.0.1:8080")
        guard let value, !value.isEmpty else {
            throw Abort(.internalServerError, reason: "AUTHENTICATION_SERVER_URL is required in production.")
        }
        guard var url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (1...65535).contains(url.port ?? 80),
              !value.contains(where: { $0.isWhitespace }) else {
            throw Abort(.internalServerError, reason: "AUTHENTICATION_SERVER_URL must be an HTTP(S) base URL without credentials, query, or fragment.")
        }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        url.path += "/auth/introspect"
        guard let endpoint = url.string else {
            throw Abort(.internalServerError, reason: "AUTHENTICATION_SERVER_URL is invalid.")
        }
        introspectionURL = URI(string: endpoint)
    }
}
