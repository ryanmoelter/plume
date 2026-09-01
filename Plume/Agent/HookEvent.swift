import Foundation

/// One line of a hook events file.
///
/// Only the fields Plume acts on are decoded; the rest of the payload is
/// ignored so a new Claude Code field never breaks parsing.
struct HookEvent: Decodable, Equatable {
    let hookEventName: String
    let sessionID: String?
    let transcriptPath: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
    }

    init(hookEventName: String, sessionID: String? = nil, transcriptPath: String? = nil, cwd: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
    }

    var kind: Kind {
        Kind(rawValue: hookEventName) ?? .unknown
    }

    enum Kind: String {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case subagentStop = "SubagentStop"
        case notification = "Notification"
        case sessionEnd = "SessionEnd"
        case unknown
    }
}
