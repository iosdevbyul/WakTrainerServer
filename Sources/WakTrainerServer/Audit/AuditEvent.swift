import Vapor

// Persist raw strings, not a PostgreSQL enum, so new event types need no schema change.
enum AuditEventType: String, Codable, Sendable {
    case signUpSucceeded, loginSucceeded, loginFailed, refreshSucceeded, refreshRejected
    case logout, logoutOtherSessions, logoutAll, sessionRevoked
    case passwordChanged, passwordResetRequested, passwordResetSucceeded
    case emailVerificationSucceeded, emailVerificationResendRequested
    case emailChangeRequested, emailChangeSucceeded, accountWithdrawn
    case loginRateLimited, emailRateLimited

    var isNoisy: Bool {
        switch self {
        case .loginFailed, .refreshRejected, .loginRateLimited, .emailRateLimited,
             .passwordResetRequested, .emailVerificationResendRequested: true
        default: false
        }
    }
}

struct AuditMetadata: Codable, Sendable {
    enum Reason: String, Codable, Sendable { case invalidCredentials, invalidRefresh, rateLimited }
    enum Endpoint: String, Codable, Sendable {
        case signup, login, refresh, logout, logoutOtherSessions, logoutAll, sessionRevoke
        case changePassword, forgotPassword, resetPassword, verifyEmail, resendVerificationEmail
        case requestEmailChange, confirmEmailChange, withdraw
    }
    enum Action: String, Codable, Sendable { case passwordReset, signUpVerification, emailChangeVerification }
    var reasonCode: Reason?
    var endpoint: Endpoint
    var statusCode: UInt
    var action: Action?
}

// No request bodies, credential-bearing models, raw identifiers, URLs or error strings.
struct AuditContext: Sendable {
    var userID: UUID?
    var sessionManagementID: UUID?
    var emailHash: String?
    var emailRateLimited: AuditMetadata.Action?
}

private struct AuditContextKey: StorageKey { typealias Value = AuditContext }
struct AuditRecorderKey: StorageKey { typealias Value = AuditLogService }

extension Request {
    var auditContext: AuditContext {
        get { storage[AuditContextKey.self] ?? .init() }
        set { storage[AuditContextKey.self] = newValue }
    }

    func auditEmail(_ email: String) {
        guard email.utf8.count <= 254 else { return }
        auditContext.emailHash = storage[AuditRecorderKey.self]?.identifierHash(email, kind: .email)
    }

    func auditIdentity(_ userID: UUID, session: RefreshToken? = nil) {
        auditContext.userID = userID
        if let session { auditContext.sessionManagementID = session.managementID ?? session.id }
    }
}
