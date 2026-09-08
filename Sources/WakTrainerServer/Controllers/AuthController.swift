//
//  AuthController.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-08-28.
//

// Sources/WakTrainerServer/Controllers/AuthController.swift

import Vapor
import Fluent

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        
        // POST /auth/login
        auth.post("login", use: login)
        
        // POST /auth/signup
        auth.post("signup", use: signUp)
        
        // POST /auth/logout
        auth.post("logout", use: logout)
        
        // DELETE /auth/withdraw
        auth.delete("withdraw", use: withdraw)
        
        // POST /auth/forgot-password
        auth.post("forgot-password", use: forgotPassword)
        
        // POST /auth/change-password
        auth.post("change-password", use: changePassword)
    }

    // POST /auth/login
    @Sendable
    func login(req: Request) async throws -> SessionResponseDTO {
        let body = try req.content.decode(AuthRequestDTO.self)

        guard body.email.contains("@"),
              body.email.contains(".") else {
            throw Abort(
                .badRequest,
                reason: "올바른 이메일 형식을 입력해주세요."
            )
        }

        guard (7...20).contains(body.password.count) else {
            throw Abort(
                .badRequest,
                reason: "비밀번호는 7자 이상 20자 이하로 입력해주세요."
            )
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == body.email)
            .first()
        else {
            throw Abort(
                .unauthorized,
                reason: "이메일 또는 비밀번호가 올바르지 않습니다."
            )
        }

        let isPasswordValid = try await req.password.async.verify(
            body.password,
            created: user.passwordHash
        )

        guard isPasswordValid else {
            throw Abort(
                .unauthorized,
                reason: "이메일 또는 비밀번호가 올바르지 않습니다."
            )
        }

        guard let userID = user.id else {
            throw Abort(.internalServerError)
        }

        let responseUser = UserResponseDTO(
            id: userID.uuidString,
            email: user.email
        )

        return SessionResponseDTO(
            user: responseUser,
            accessToken: "access_token_\(UUID().uuidString)",
            refreshToken: "refresh_token_\(UUID().uuidString)"
        )
    }

    // POST /auth/signup
    @Sendable
    func signUp(req: Request) async throws -> SessionResponseDTO {
        let body = try req.content.decode(AuthRequestDTO.self)

        guard (7...20).contains(body.password.count) else {
            throw Abort(
                .badRequest,
                reason: "비밀번호는 7자 이상 20자 이하로 입력해주세요."
            )
        }

        guard body.email.contains("@"),
              body.email.contains(".") else {
            throw Abort(
                .badRequest,
                reason: "올바른 이메일 형식을 입력해주세요."
            )
        }

        let existingUser = try await User.query(on: req.db)
            .filter(\.$email == body.email)
            .first()

        if existingUser != nil {
            throw Abort(
                .conflict,
                reason: "이미 사용 중인 이메일입니다."
            )
        }

        let passwordHash = try await req.password.async.hash(body.password)

        let user = User(
            email: body.email,
            passwordHash: passwordHash
        )

        try await user.create(on: req.db)

        guard let userID = user.id else {
            throw Abort(.internalServerError)
        }

        let newUser = UserResponseDTO(
            id: userID.uuidString,
            email: user.email
        )

        return SessionResponseDTO(
            user: newUser,
            accessToken: "access_token_\(UUID().uuidString)",
            refreshToken: "refresh_token_\(UUID().uuidString)"
        )
    }

    // POST /auth/logout
    @Sendable
    func logout(req: Request) async throws -> MessageResponseDTO {
        // TODO: AccessToken/RefreshToken 무효화 로직 추가 예정
        return MessageResponseDTO(message: "Successfully logged out.")
    }

    // DELETE /auth/withdraw
    @Sendable
    func withdraw(req: Request) async throws -> MessageResponseDTO {
        // TODO: AccessToken 검증 및 DB 사용자 삭제 로직 추가 예정
        return MessageResponseDTO(message: "Account withdrawn successfully.")
    }

    // POST /auth/forgot-password
    @Sendable
    func forgotPassword(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(ForgotPasswordRequestDTO.self)
        
        return MessageResponseDTO(message: "Password reset email sent to \(body.email).")
    }
    
    // POST /auth/change-password
    @Sendable
    func changePassword(req: Request) async throws -> MessageResponseDTO {
        let body = try req.content.decode(ChangePasswordRequestDTO.self)

        guard !body.currentPassword.isEmpty,
              !body.newPassword.isEmpty else {
            throw Abort(
                .badRequest,
                reason: "Passwords must not be empty."
            )
        }

        return MessageResponseDTO(
            message: "Password changed successfully."
        )
    }
}

