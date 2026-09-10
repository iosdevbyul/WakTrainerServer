import Vapor

struct APIValidationDetail: Codable, Sendable {
    enum Field: String, Codable, Sendable { case email, newEmail, sessionID }
    enum Code: String, Codable, Sendable { case invalidFormat = "INVALID_FORMAT", mustDiffer = "MUST_DIFFER" }
    let field: Field
    let code: Code
}

struct APIErrorResponseDTO: Content {
    let error: Bool
    let status: Int
    let code: APIErrorCode
    let message: String
    let reason: String
    let details: [APIValidationDetail]?

    // Only the middleware constructs the payload from its selected HTTP status.
    init(status: HTTPResponseStatus, code: APIErrorCode, message: String, details: [APIValidationDetail]?) {
        self.error = true
        self.status = Int(status.code)
        self.code = code
        self.message = message
        self.reason = message
        self.details = details
    }
}
