import Vapor

/// The handler has returned only after its business transaction commits. Errors
/// cannot produce success events. This middleware never decodes bodies or JWTs.
struct AuditLogMiddleware: AsyncMiddleware {
    let service: AuditLogService
    let event: AuditEventType
    let endpoint: AuditMetadata.Endpoint

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        req.storage[AuditRecorderKey.self] = service
        do {
            let response = try await next.respond(to: req)
            await record(req, status: response.status)
            return response
        } catch {
            let status = (error as? any AbortError)?.status ?? .internalServerError
            await record(req, status: status)
            throw error
        }
    }

    private func record(_ req: Request, status: HTTPResponseStatus) async {
        let context = req.auditContext
        if let action = context.emailRateLimited {
            await service.record(.emailRateLimited, context: context,
                metadata: .init(reasonCode: .rateLimited, endpoint: endpoint, statusCode: status.code, action: action), on: req)
        }
        var result: AuditEventType?
        var reason: AuditMetadata.Reason?
        if status == .ok { result = event }
        else if event == .loginSucceeded, status == .unauthorized { result = .loginFailed; reason = .invalidCredentials }
        else if event == .loginSucceeded, status == .tooManyRequests { result = .loginRateLimited; reason = .rateLimited }
        else if event == .refreshSucceeded, status == .unauthorized { result = .refreshRejected; reason = .invalidRefresh }
        if let result {
            await service.record(result, context: context,
                metadata: .init(reasonCode: reason, endpoint: endpoint, statusCode: status.code), on: req)
        }
    }
}
