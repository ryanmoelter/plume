import Foundation

nonisolated struct CmuxHookSessions: Decodable {
    let activeSessionsBySurface: [String: CmuxActiveSession]?
    let activeSessionsByWorkspace: [String: CmuxActiveSession]?
    let sessions: [String: CmuxSessionRecord]?
}

nonisolated struct CmuxActiveSession: Decodable {
    let sessionId: String?
    let updatedAt: Double?
}

nonisolated struct CmuxSessionRecord: Decodable {
    let sessionId: String?
    let workspaceId: String?
    let surfaceId: String?
    let cwd: String?
    let startedAt: Double?
    let updatedAt: Double?
    let isRestorable: Bool?
    let lastPermissionMode: String?
    let transcriptPath: String?
    let launchCommand: CmuxLaunchCommand?
}

nonisolated struct CmuxLaunchCommand: Decodable {
    let launcher: String?
    let executablePath: String?
    let arguments: [String]?
    let workingDirectory: String?
}
