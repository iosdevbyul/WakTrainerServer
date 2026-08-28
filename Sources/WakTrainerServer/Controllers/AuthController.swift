//
//  AuthController.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-08-28.
//

import Vapor

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        
        auth.post("login", use: login)
        auth.post("signup", use: signUp)
        auth.post("logout", use: logout)
        auth.delete("withdraw", use: withdraw)
        auth.post("forgot-password", use: forgotPassword)
    }

    // POST /auth/login
    @Sendable
    func login(req: Request) async throws -> SessionResponse {
        let body = try req.content.decode(AuthRequest.self)
        
        let mockUser = UserResponse(
            id: UUID().uuidString,
            email: body.email
        )
        
        return SessionResponse(
            user: mockUser,
            accessToken: "access_token_\(UUID().uuidString)",
            refreshToken: "refresh_token_\(UUID().uuidString)"
        )
    }

    // POST /auth/signup
    @Sendable
    func signUp(req: Request) async throws -> SessionResponse {
        let body = try req.content.decode(AuthRequest.self)
        
        let newUser = UserResponse(
            id: UUID().uuidString,
            email: body.email
        )
        
        return SessionResponse(
            user: newUser,
            accessToken: "access_token_\(UUID().uuidString)",
            refreshToken: "refresh_token_\(UUID().uuidString)"
        )
    }

    // POST /auth/logout
    @Sendable
    func logout(req: Request) async throws -> MessageResponse {
        return MessageResponse(message: "Successfully logged out.")
    }

    // DELETE /auth/withdraw
    @Sendable
    func withdraw(req: Request) async throws -> MessageResponse {
        return MessageResponse(message: "Account withdrawn successfully.")
    }

    // POST /auth/forgot-password
    @Sendable
    func forgotPassword(req: Request) async throws -> MessageResponse {
        let body = try req.content.decode(ForgotPasswordRequest.self)
        return MessageResponse(message: "Password reset email sent to \(body.email).")
    }
}
