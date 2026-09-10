import Vapor
import Foundation

struct APIErrorMiddleware: AsyncMiddleware {
    static func install(on app: Application) {
        // Replace the default handler rather than letting it consume errors before us.
        app.middleware = .init()
        app.middleware.use(APIErrorMiddleware())
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            let status: HTTPResponseStatus
            let code: APIErrorCode
            let message: String
            let details: [APIValidationDetail]?
            var headers = HTTPHeaders()
            if let api = error as? APIError {
                status = api.status
                code = api.code
                message = api.message
                details = api.details
                headers = api.headers
            } else {
                status = (error as? any AbortError)?.status ?? .internalServerError
                switch status.code {
                case 400: code = .invalidRequest
                case 401: code = .authenticationRequired
                case 403: code = .forbidden
                case 404: code = .notFound
                case 413: code = .payloadTooLarge
                case 415: code = .unsupportedMediaType
                case 429: code = .rateLimited
                case 500...599: code = .internalError
                default: code = .httpError
                }
                message = code.message
                details = nil
                // Never copy arbitrary error headers or their untrusted values.
                if status == .tooManyRequests, let abort = error as? any AbortError,
                   let value = abort.headers.first(name: "Retry-After"), let seconds = Int(value), seconds > 0 {
                    headers.replaceOrAdd(name: "Retry-After", value: String(seconds))
                }
            }
            // Do not log the error, URL, headers, body, SQL bindings or decoder context.
            request.logger.log(level: status.code >= 500 ? .error : .notice,
                "API request failed", metadata: ["status": .string(String(status.code)), "code": .string(code.rawValue)])
            let payload = APIErrorResponseDTO(status: status, code: code, message: message, details: details)
            do {
                let data = try JSONEncoder().encode(payload)
                headers.contentType = .json
                return Response(status: status, headers: headers, body: .init(data: data))
            } catch {
                // A fixed, non-throwing JSON fallback has no diagnostic interpolation.
                let fallback = APIErrorCode.internalError
                let message = "Internal server error."
                let body = "{\"error\":true,\"status\":\(fallback.status.code),\"code\":\"\(fallback.rawValue)\",\"message\":\"\(message)\",\"reason\":\"\(message)\"}"
                return Response(status: fallback.status, headers: ["Content-Type": "application/json"], body: .init(string: body))
            }
        }
    }
}
