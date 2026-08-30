//
//  AuthDTOs.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-08-28.
//

// Sources/WakTrainerServer/DTOs/AuthDTOs.swift

import Vapor

// MARK: - Request DTOs
/// iOS 클라이언트의 LoginRequestDTO / SignUpRequestDTO와 매핑
struct AuthRequestDTO: Content {
    let email: String
    let password: String
}

/// iOS 클라이언트의 ForgotPasswordRequestDTO와 매핑
struct ForgotPasswordRequestDTO: Content {
    let email: String
}

// MARK: - Response DTOs
struct UserResponseDTO: Content {
    let id: String
    let email: String
}

struct SessionResponseDTO: Content {
    let user: UserResponseDTO
    let accessToken: String
    let refreshToken: String?
}

struct MessageResponseDTO: Content {
    let message: String
}
