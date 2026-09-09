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

    func send(_ message: EmailMessage, on req: Request) async throws {
        sentEmail = message.recipient
        sentResetURL = message.html.components(separatedBy: "href=\"").dropFirst().first?
            .components(separatedBy: "\"").first
    }
}
