//
//  User.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import Fluent
import Vapor

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
    }
}
