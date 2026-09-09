import Vapor

struct SessionListResponseDTO: Content {
    let sessions: [ManagedSessionResponseDTO]
}

/// Dates are distinct: current row creation, login start, and latest successful refresh.
/// Optional timestamps/metadata may be absent for legacy sessions.
struct ManagedSessionResponseDTO: Content {
    let id: String // Stable management ID, not the rotating JWT sid.
    let createdAt: Date?
    let startedAt: Date?
    let expiresAt: Date
    let lastRefreshedAt: Date?
    let isCurrent: Bool
    let deviceName: String?
}
