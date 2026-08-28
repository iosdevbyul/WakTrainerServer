import Vapor

// 1. Vapor의 Content 프로토콜 채택 (iOS의 Codable과 동일)
struct UserResponse: Content {
    let name: String
    let role: String
    let isDeveloper: Bool
}

func routes(_ app: Application) throws {
    app.get("hello") { req async in
        "Hello, world!"
    }

    // 2. http://127.0.0.1:8080/user 요청을 처리할 API 추가
    app.get("user") { req async -> UserResponse in
        return UserResponse(
            name: "comatoki",
            role: "iOS Developer",
            isDeveloper: true
        )
    }
}
