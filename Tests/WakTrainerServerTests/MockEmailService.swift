import Foundation
import Vapor
@testable import WakTrainerServer

final class MockEmailService: EmailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [EmailMessage] = []
    private var fails = false

    var shouldFail: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }

    var sentEmail: String? { lock.withLock { messages.last?.recipient } }
    var sentResetURL: String? { url(subject: "WakTrainer 비밀번호 재설정") }
    var sentVerificationURL: String? { url(subject: "WakTrainer 이메일 인증") }
    var sentCount: Int { lock.withLock { messages.count } }

    private func url(subject: String) -> String? {
        lock.withLock {
            messages.last { $0.subject == subject }?.html
                .components(separatedBy: "href=\"").dropFirst().first?
                .components(separatedBy: "\"").first?
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    func send(_ message: EmailMessage, on req: Request) async throws {
        try lock.withLock {
            if fails { throw Abort(.badGateway) }
            messages.append(message)
        }
    }
}
