//
//  ResetPasswordRequestDTO.swift
//  WakTrainerServer
//
//  Created by COMATOKI on 2026-09-08.
//

import Vapor

struct ResetPasswordRequestDTO: Content {
    let token: String
    let newPassword: String
}
