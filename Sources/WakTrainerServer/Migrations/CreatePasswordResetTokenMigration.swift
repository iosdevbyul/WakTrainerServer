//
//  CreatePasswordResetTokenMigration.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import Fluent

struct CreatePasswordResetTokenMigration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema)
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references(
                    User.schema,
                    .id,
                    onDelete: .cascade
                )
            )
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema).delete()
    }
}
