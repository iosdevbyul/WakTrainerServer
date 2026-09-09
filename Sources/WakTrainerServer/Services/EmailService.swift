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
