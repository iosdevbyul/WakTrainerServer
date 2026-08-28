//
//  AuthDTOs.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-08-28.
//

import Vapor

// MARK: - Request DTOs
struct AuthRequest: Content {
    let email: String
    let password: String
}

struct ForgotPasswordRequest: Content {
    let email: String
}

// MARK: - Response DTOs
struct UserResponse: Content {
    let id: String
    let email: String
}

struct SessionResponse: Content {
    let user: UserResponse
    let accessToken: String
    let refreshToken: String?
}

struct MessageResponse: Content {
    let message: String
}
