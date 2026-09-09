//
//  EmailService.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import Foundation
import Vapor

/// Transport abstraction. Application code uses EmailService.withRequest so the
/// quota is consumed before account lookup or message/token preparation.
protocol EmailSending: Sendable {
    func send(_ message: EmailMessage, on req: Request) async throws
}

struct EmailMessage: Sendable {
    let recipient: String
    let subject: String
    let html: String

    static func signUpVerification(to email: String, verificationURL: String) -> Self {
        let escapedURL = verificationURL.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return .init(recipient: email, subject: "WakTrainer 이메일 인증", html: """
            <p>아래 링크에서 이메일 인증을 완료해주세요. 링크는 24시간 동안 유효합니다.</p>
            <p><a href="\(escapedURL)">이메일 인증</a></p>
            """)
    }

    static func emailChangeVerification(to email: String, verificationURL: String) -> Self {
        let escapedURL = verificationURL.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return .init(recipient: email, subject: "WakTrainer 이메일 변경 인증", html: """
            <p>로그인한 계정에서 아래 링크의 이메일 변경을 확인해주세요. 링크는 30분 동안 유효합니다.</p>
            <p><a href="\(escapedURL)">이메일 변경 확인</a></p>
            """)
    }

    static func passwordReset(to email: String, resetURL: String) -> Self {
        .init(recipient: email, subject: "WakTrainer 비밀번호 재설정", html: """
            <p>비밀번호를 재설정하려면 아래 링크를 눌러주세요.</p>
            <p><a href="\(resetURL)">비밀번호 재설정</a></p>
            """)
    }
}

struct EmailService: Sendable {
    private let transport: any EmailSending
    private let limiter: EmailRateLimitService

    init(transport: (any EmailSending)? = nil,
         limiter: EmailRateLimitService = .init()) {
        self.transport = transport ?? ResendEmailTransport()
        self.limiter = limiter
    }

    /// Returns false when throttled. The preparation closure is never run then.
    /// The message recipient is bound to the quota; each request sends at most once.
    func withRequest(to email: String, action: EmailAction, on req: Request,
                     prepare: () async throws -> EmailMessage?) async throws -> Bool {
        guard try await limiter.allow(to: email, action: action, on: req) else { return false }
        if let message = try await prepare() {
            guard message.recipient == email else { throw Abort(.internalServerError) }
            try await transport.send(message, on: req)
        }
        return true
    }
}

private struct ResendEmailTransport: EmailSending {
    func send(_ message: EmailMessage, on req: Request) async throws {
        guard let apiKey = Environment.get("RESEND_API_KEY"),
              !apiKey.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "RESEND_API_KEY environment variable is required."
            )
        }

        let body = ResendEmailRequest(
            from: "WakTrainer <onboarding@resend.dev>",
            to: [message.recipient],
            subject: message.subject,
            html: message.html
        )

        let response = try await req.client.post(
            URI(string: "https://api.resend.com/emails")
        ) { request in
            request.headers.bearerAuthorization = BearerAuthorization(
                token: apiKey
            )

            request.headers.contentType = .json
            try request.content.encode(body)
        }

        guard response.status.code >= 200,
              response.status.code < 300 else {
            throw Abort(
                .badGateway,
                reason: "Failed to send password reset email."
            )
        }
    }
}

private struct ResendEmailRequest: Content {
    let from: String
    let to: [String]
    let subject: String
    let html: String
}
