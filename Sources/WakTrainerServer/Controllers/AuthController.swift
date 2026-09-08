//
//  AuthController.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-08-28.
//

// Sources/WakTrainerServer/Controllers/AuthController.swift

import Vapor

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
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
        
        let mockUser = UserResponseDTO(
            id: UUID().uuidString,
            email: body.email
        )
        
        return SessionResponseDTO(
            user: mockUser,
            accessToken: "access_token_\(UUID().uuidString)",
            refreshToken: "refresh_token_\(UUID().uuidString)"
        )
    }

    // POST /auth/signup
    @Sendable
    func signUp(req: Request) async throws -> SessionResponseDTO {
        let body = try req.content.decode(AuthRequestDTO.self)
        
        let newUser = UserResponseDTO(
            id: UUID().uuidString,
            email: body.email
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

