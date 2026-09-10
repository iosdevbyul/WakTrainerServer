@testable import WakTrainerServer
import Testing
import VaporTesting
import Foundation

private struct DiagnosticError: DebuggableError {
    let identifier = "sensitive-diagnostic"
    let reason: String
}

@Suite("API error middleware")
struct APIErrorMiddlewareTests {
    @Test func productionContractsAndRedaction() async throws {
        let app = try await Application.make(.production)
        do {
            APIErrorMiddleware.install(on: app)
            let sentinels = ["SELECT password_hash FROM users", "DB connection failure detail", "JWT_SECRET",
                "private-env-value", "/private/server/config.swift", "stack trace frame", "Authorization",
                "Bearer private-access", "private-refresh-token", "private-password", "private-verification-token",
                "private-reset-token", "private-verification-code", "private-provider-key", "raw-provider-response"]
            let secret = sentinels.joined(separator: " | ")
            for code in APIErrorCode.allCases {
                app.get("typed", .constant(code.rawValue)) { _ -> String in throw APIError(code) }
            }
            app.get("raw-abort") { _ -> String in throw Abort(.internalServerError, reason: secret) }
            app.get("raw-client-abort") { _ -> String in throw Abort(.badRequest, reason: secret) }
            app.get("raw-debuggable") { _ -> String in throw DiagnosticError(reason: secret) }
            app.get("raw-unexpected") { _ -> String in throw NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]) }
            app.get("raw-decoder") { _ -> String in
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret,
                    underlyingError: NSError(domain: secret, code: 1)))
            }
            app.get("raw-headers") { _ -> String in
                throw Abort(.tooManyRequests, headers: ["Authorization": secret, "Retry-After": secret, "Set-Cookie": secret], reason: secret)
            }
            app.get("raw-status") { _ -> String in throw Abort(.imATeapot, reason: secret) }
            app.post("decode") { req -> String in _ = try req.content.decode(AuthRequestDTO.self); return "ok" }
            for code in APIErrorCode.allCases {
                let response = try await app.sendRequest(.GET, "typed/" + code.rawValue)
                let payload = try response.content.decode(APIErrorResponseDTO.self)
                #expect(response.status == code.status)
                #expect(payload.status == response.status.code)
                #expect(payload.code == code)
                #expect(payload.error)
                #expect(payload.message == payload.reason)
                #expect(payload.details == nil)
                #expect(response.headers.contentType == .json)
                struct Legacy: Decodable { let error: Bool; let reason: String }
                #expect(try response.content.decode(Legacy.self).reason == payload.message)
            }
            for path in ["raw-abort", "raw-client-abort", "raw-debuggable", "raw-unexpected", "raw-decoder", "raw-headers", "raw-status", "missing"] {
                let response = try await app.sendRequest(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: "private-access")
                })
                let payload = try response.content.decode(APIErrorResponseDTO.self)
                #expect(payload.status == response.status.code)
                #expect(payload.reason == payload.message)
                for value in sentinels { #expect(!response.body.string.contains(value)) }
                #expect(response.headers.first(name: "Authorization") == nil)
                #expect(response.headers.first(name: "Set-Cookie") == nil)
                #expect(response.headers.first(name: "Retry-After") == nil)
                if ["raw-abort", "raw-debuggable", "raw-unexpected"].contains(path) {
                    #expect(response.status == .internalServerError)
                    #expect(payload.code == .internalError)
                }
                if path == "missing" { #expect(response.status == .notFound); #expect(payload.code == .notFound) }
                if path == "raw-status" { #expect(response.status == .imATeapot); #expect(payload.code == .httpError) }
                if path == "raw-decoder" || path == "raw-client-abort" { #expect(payload.code == .invalidRequest) }
            }
            for body in ["{", "{}", "{\"email\":123,\"password\":\"private-password\"}"] {
                let response = try await app.sendRequest(.POST, "decode", beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: body)
                })
                #expect(response.status == .badRequest)
                #expect(try response.content.decode(APIErrorResponseDTO.self).code == .invalidRequest)
                #expect(!response.body.string.contains("private-password"))
            }
            let media = try await app.sendRequest(.POST, "decode")
            #expect(media.status == .unsupportedMediaType)
            #expect(try media.content.decode(APIErrorResponseDTO.self).code == .unsupportedMediaType)
            let wrongMethod = try await app.sendRequest(.DELETE, "decode")
            #expect(wrongMethod.status == .notFound)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
