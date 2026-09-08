//
//  MockEmailService.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-09.
//

import Vapor
@testable import WakTrainerServer

final class MockEmailService: EmailSending, @unchecked Sendable {
    private(set) var sentEmail: String?
    private(set) var sentResetURL: String?

    func sendPasswordResetEmail(
        to email: String,
        resetURL: String,
        on req: Request
    ) async throws {
        sentEmail = email
        sentResetURL = resetURL
    }
}
