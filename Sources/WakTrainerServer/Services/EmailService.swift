//
//  EmailService.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import Foundation
import Vapor

struct EmailService {
    private let apiKey: String

    init() {
        guard let apiKey = Environment.get("RESEND_API_KEY"),
              !apiKey.isEmpty else {
            fatalError("RESEND_API_KEY environment variable is required.")
        }

        self.apiKey = apiKey
    }

    func sendPasswordResetEmail(
        to email: String,
        resetURL: String,
        on req: Request
    ) async throws {
        let body = ResendEmailRequest(
            from: "WakTrainer <onboarding@resend.dev>",
            to: [email],
            subject: "WakTrainer 비밀번호 재설정",
            html: """
            <p>비밀번호를 재설정하려면 아래 링크를 눌러주세요.</p>
            <p><a href="\(resetURL)">비밀번호 재설정</a></p>
            """
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
