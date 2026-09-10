import Vapor

/// Explicit public contract; never derived from Swift names or diagnostic strings.
enum APIErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case validationFailed = "VALIDATION_FAILED"
    case invalidCredentials = "INVALID_CREDENTIALS"
    case currentPasswordInvalid = "CURRENT_PASSWORD_INVALID"
    case authenticationRequired = "AUTHENTICATION_REQUIRED"
    case accessTokenInvalidOrExpired = "ACCESS_TOKEN_INVALID_OR_EXPIRED"
    case sessionInvalid = "SESSION_INVALID"
    case refreshTokenRejected = "REFRESH_TOKEN_REJECTED"
    case passwordResetTokenInvalid = "PASSWORD_RESET_TOKEN_INVALID"
    case emailVerificationTokenInvalid = "EMAIL_VERIFICATION_TOKEN_INVALID"
    case emailChangeTokenInvalid = "EMAIL_CHANGE_TOKEN_INVALID"
    case emailAlreadyExists = "EMAIL_ALREADY_EXISTS"
    case notFound = "NOT_FOUND"
    case rateLimited = "RATE_LIMITED"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE"
    case forbidden = "FORBIDDEN"
    case emailVerificationRequired = "EMAIL_VERIFICATION_REQUIRED"
    case internalError = "INTERNAL_ERROR"
    case emailDeliveryFailed = "EMAIL_DELIVERY_FAILED"
    case httpError = "HTTP_ERROR"

    var status: HTTPResponseStatus {
        switch self {
        case .invalidRequest, .validationFailed, .passwordResetTokenInvalid,
             .emailVerificationTokenInvalid, .emailChangeTokenInvalid: return .badRequest
        case .invalidCredentials, .currentPasswordInvalid, .authenticationRequired,
             .accessTokenInvalidOrExpired, .sessionInvalid, .refreshTokenRejected: return .unauthorized
        case .emailAlreadyExists: return .conflict
        case .notFound: return .notFound
        case .rateLimited: return .tooManyRequests
        case .payloadTooLarge: return .payloadTooLarge
        case .unsupportedMediaType: return .unsupportedMediaType
        case .forbidden, .emailVerificationRequired: return .forbidden
        case .emailDeliveryFailed: return .badGateway
        case .internalError, .httpError: return .internalServerError
        }
    }

    var message: String {
        switch self {
        case .invalidRequest: return "요청 형식을 확인해주세요."
        case .validationFailed: return "입력한 정보를 다시 확인해주세요."
        case .invalidCredentials: return "이메일 또는 비밀번호가 올바르지 않습니다."
        case .currentPasswordInvalid: return "현재 비밀번호가 올바르지 않습니다."
        case .authenticationRequired, .accessTokenInvalidOrExpired: return "유효한 인증 토큰이 필요합니다."
        case .sessionInvalid: return "만료되었거나 폐기된 세션입니다."
        case .refreshTokenRejected: return "Unauthorized"
        case .passwordResetTokenInvalid: return "유효하지 않거나 만료된 비밀번호 재설정 토큰입니다."
        case .emailVerificationTokenInvalid: return "유효하지 않거나 만료된 이메일 인증 토큰입니다."
        case .emailChangeTokenInvalid: return "유효하지 않거나 만료된 이메일 변경 토큰입니다."
        case .emailAlreadyExists: return "이미 사용 중인 이메일입니다."
        case .notFound: return "요청한 정보를 찾을 수 없습니다."
        case .rateLimited: return "잠시 후 다시 요청해주세요."
        case .payloadTooLarge: return "요청 크기가 너무 큽니다."
        case .unsupportedMediaType: return "지원하지 않는 요청 형식입니다."
        case .forbidden: return "요청을 수행할 권한이 없습니다."
        case .emailVerificationRequired: return "이메일 인증이 필요합니다."
        case .emailDeliveryFailed: return "이메일을 발송하지 못했습니다. 잠시 후 다시 시도해주세요."
        case .internalError: return "요청 처리 중 문제가 발생했습니다. 잠시 후 다시 시도해주세요."
        case .httpError: return "요청을 처리할 수 없습니다."
        }
    }
}

/// Closed variants preserve legacy public messages without accepting arbitrary strings.
struct APIError: AbortError, Sendable {
    enum Variant: Sendable {
        case email, password, passwordChange, emailChangeInput, sameEmail, sessionID
        case sessionNotFound, malformedResetToken, loginRateLimit, legacyUnauthorized
    }
    let code: APIErrorCode
    let variant: Variant?
    let retryAfter: Int?
    init(_ code: APIErrorCode, variant: Variant? = nil, retryAfter: Int? = nil) {
        self.code = code
        self.variant = variant
        self.retryAfter = retryAfter
    }
    var status: HTTPResponseStatus { code.status }
    var headers: HTTPHeaders {
        guard code == .rateLimited, let retryAfter else { return [:] }
        return ["Retry-After": String(max(1, retryAfter))]
    }
    var reason: String { message }
    var message: String {
        switch variant {
        case .email: return "올바른 이메일 형식을 입력해주세요."
        case .password: return "비밀번호는 7자 이상 20자 이하, UTF-8 기준 72바이트 이하로 입력해주세요."
        case .passwordChange: return "현재 비밀번호와 다른 새 비밀번호를 입력해주세요."
        case .emailChangeInput: return "올바른 이메일과 현재 비밀번호를 입력해주세요."
        case .sameEmail: return "현재 이메일과 다른 이메일을 입력해주세요."
        case .sessionID: return "올바른 세션 ID를 입력해주세요."
        case .sessionNotFound: return "세션을 찾을 수 없습니다."
        case .malformedResetToken: return "유효하지 않은 비밀번호 재설정 토큰입니다."
        case .loginRateLimit: return "로그인 요청이 너무 많습니다. 잠시 후 다시 시도해주세요."
        case .legacyUnauthorized: return "Unauthorized"
        case nil: return code.message
        }
    }
    var details: [APIValidationDetail]? {
        guard code == .validationFailed else { return nil }
        switch variant {
        case .email: return [.init(field: .email, code: .invalidFormat)]
        case .sessionID: return [.init(field: .sessionID, code: .invalidFormat)]
        case .sameEmail: return [.init(field: .newEmail, code: .mustDiffer)]
        // Compound password/input guards do not reveal which credential check failed.
        default: return nil
        }
    }
}
