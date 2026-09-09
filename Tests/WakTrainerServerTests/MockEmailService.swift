import Foundation
import Vapor
@testable import WakTrainerServer

final class MockEmailService: EmailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [EmailMessage] = []
    private var fails = false
    private var nextChangeFailure: EmailDeliveryGate?

    var shouldFail: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }

    var sentEmail: String? { lock.withLock { messages.last?.recipient } }
    var sentResetURL: String? { url(subject: "WakTrainer 비밀번호 재설정") }
    var sentVerificationURL: String? { url(subject: "WakTrainer 이메일 인증") }
    var sentEmailChangeURL: String? { url(subject: "WakTrainer 이메일 변경 인증") }
    var sentCount: Int { lock.withLock { messages.count } }

    private func url(subject: String) -> String? {
        lock.withLock {
            messages.last { $0.subject == subject }?.html
                .components(separatedBy: "href=\"").dropFirst().first?
                .components(separatedBy: "\"").first?
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    func failNextEmailChange(after gate: EmailDeliveryGate) {
        lock.withLock { nextChangeFailure = gate }
    }

    func send(_ message: EmailMessage, on req: Request) async throws {
        let gate: EmailDeliveryGate? = lock.withLock {
            guard message.subject == "WakTrainer 이메일 변경 인증" else { return nil }
            let gate = nextChangeFailure
            nextChangeFailure = nil
            return gate
        }
        if let gate {
            await gate.block()
            throw Abort(.badGateway)
        }
        try lock.withLock {
            if fails { throw Abort(.badGateway) }
            messages.append(message)
        }
    }
}

/// Deterministic provider delay: exercise cleanup after a newer request commits.
actor EmailDeliveryGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    func waitUntilBlocked() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
