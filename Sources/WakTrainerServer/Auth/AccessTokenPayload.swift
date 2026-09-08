//
//  AccessTokenPayload.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import JWT
import Foundation

struct AccessTokenPayload: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case sessionID = "sid"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var sessionID: UUID?

    init(
        userID: UUID,
        expirationDate: Date,
        sessionID: UUID? = nil
    ) {
        self.subject = SubjectClaim(value: userID.uuidString)
        self.expiration = ExpirationClaim(value: expirationDate)
        self.sessionID = sessionID
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }
}
