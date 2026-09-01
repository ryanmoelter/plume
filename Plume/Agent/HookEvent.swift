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
    /// Why a `SessionStart` fired: `startup`, `resume`, `clear`, `compact`.
    let source: String?
    /// Why a `SessionEnd` fired; `clear` means the conversation was reset,
    /// not that the agent stopped.
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case source
        case reason
    }

    init(
        hookEventName: String,
        sessionID: String? = nil,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        reason: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.source = source
        self.reason = reason
    }

    /// A `/clear` ends the old session and starts a new one back to back. The
    /// `SessionEnd` still carries the *old* session ID, so treating it like
    /// any other event would write the discarded conversation's ID back onto
    /// the tab.
    var endsClearedSession: Bool {
        kind == .sessionEnd && reason == "clear"
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
