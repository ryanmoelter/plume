import Foundation

/// How the host answers a `can_use_tool` control request.
enum PermissionDecision: Equatable {
    /// `updatedInput` is the hook for editing a call before it runs, and for
    /// carrying an `AskUserQuestion`'s answers.
    case allow(updatedInput: [String: JSONValue])
    case deny(message: String)
}

/// When a user message written while a turn runs reaches the model.
/// `docs/headless-protocol.md` has the measured behavior of each.
enum UserTurnPriority: String {
    /// Ends the running turn, then runs the message as a new one.
    case now
    /// Joins the running turn at its next API request, which is usually
    /// after the tool call in flight returns.
    case next
    /// Waits for the running turn's `result`, then runs as its own turn.
    case later
}

/// Builds the NDJSON lines Plume writes to `claude -p`'s stdin.
enum StreamJSONEncoder {
    static func userTurn(text: String) -> String? {
        userTurn(blocks: [.text(text)])
    }

    /// `priority` says when a message written mid-turn reaches the model —
    /// see `UserTurnPriority`. Nil leaves it to the CLI's default.
    static func userTurn(blocks: [UserContentBlock], priority: UserTurnPriority? = nil) -> String? {
        var object: [String: JSONValue] = [
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array(blocks.map(\.json))
            ])
        ]
        if let priority { object["priority"] = .string(priority.rawValue) }
        return line(object)
    }

    static func initialize(requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("initialize"),
            "hooks": .object([:])
        ])
    }

    /// `cancelQueued` also drops the user turns the CLI holds behind the
    /// running one.
    static func interrupt(requestID: String, cancelQueued: Bool = false) -> String? {
        var body: [String: JSONValue] = ["subtype": .string("interrupt")]
        if cancelQueued { body["cancel_queued"] = .bool(true) }
        return controlRequest(id: requestID, body: body)
    }

    static func setPermissionMode(_ mode: String, requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("set_permission_mode"),
            "mode": .string(mode)
        ])
    }

    static func setModel(_ model: String, requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("set_model"),
            "model": .string(model)
        ])
    }

    /// Asks the CLI to name the conversation.
    ///
    /// `description` is required and must be a string; the CLI rejects the
    /// request outright without one. It is the text the title is drawn from,
    /// not the conversation — an empty one is answered with a null title.
    ///
    /// The reply carries the title. The CLI also appends an `ai-title` line
    /// to the transcript, but only for a session's first title.
    static func generateSessionTitle(description: String, requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("generate_session_title"),
            "description": .string(description)
        ])
    }

    /// Asks the CLI to publish this conversation to claude.ai/code, or to
    /// tear that bridge down.
    ///
    /// `work_secret` and `reattach_session_id` are deliberately omitted. They
    /// select the worker-credential path, where a host that already owns a
    /// cloud session attaches this process to it; Plume owns a local session
    /// and publishes it under the user's own account, exactly as the CLI's
    /// own `/rc` does. Sending a secret with nothing to reattach to is
    /// refused outright.
    static func remoteControl(enabled: Bool, name: String?, requestID: String) -> String? {
        var body: [String: JSONValue] = [
            "subtype": .string("remote_control"),
            "enabled": .bool(enabled)
        ]
        if let name, !name.isEmpty { body["name"] = .string(name) }
        return controlRequest(id: requestID, body: body)
    }

    /// Asks a side question, answered from main context without disturbing
    /// the main conversation or writing to its transcript.
    static func sideQuestion(question: String, requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("side_question"),
            "question": .string(question)
        ])
    }

    static func getContextUsage(requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("get_context_usage"),
            "detail": .string("summary")
        ])
    }

    /// Cuts the conversation back to just before `targetMessageUUID`, so that
    /// message can be asked again. The reply carries the target's own text as
    /// `prefillText`, for editing and resending.
    ///
    /// `lastSeenMessageUUID` is the newest user message the host has rendered.
    /// The CLI refuses with `stale_target` without it, since a target chosen
    /// against a conversation that has moved on would cut the wrong place.
    ///
    /// The cut is append-only on disk: nothing is deleted, and the rows left
    /// behind stay readable as an abandoned branch. It does not survive into
    /// a new process, though — the abandoned rows leave the CLI's live chain,
    /// so rewinding back onto one answers `target_not_found`.
    static func rewindConversation(
        targetMessageUUID: String,
        lastSeenMessageUUID: String,
        requestID: String
    ) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("rewind_conversation"),
            "target_message_uuid": .string(targetMessageUUID),
            "last_seen_user_message_uuid": .string(lastSeenMessageUUID)
        ])
    }

    /// A bare success, for answering a CLI-originated request Plume has
    /// nothing to say about. Dropping one instead leaves the CLI waiting.
    static func controlSuccess(requestID: String) -> String? {
        line([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": .object([:])
            ])
        ])
    }

    static func permissionResponse(requestID: String, decision: PermissionDecision) -> String? {
        let payload: [String: JSONValue]
        switch decision {
        case .allow(let updatedInput):
            payload = ["behavior": .string("allow"), "updatedInput": .object(updatedInput)]
        case .deny(let message):
            payload = ["behavior": .string("deny"), "message": .string(message)]
        }
        return line([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": .object(payload)
            ])
        ])
    }

    /// Answers reach the model as a map of question text to chosen labels,
    /// alongside the original questions. Allowing the call without one tells
    /// the model nothing was chosen, which is how a dismissal is expressed.
    static func answeredQuestionInput(
        original: [String: JSONValue],
        answers: [String: String]
    ) -> [String: JSONValue] {
        var input = original
        input["answers"] = .object(answers.mapValues { JSONValue.string($0) })
        return input
    }

    private static func controlRequest(id: String, body: [String: JSONValue]) -> String? {
        line([
            "type": .string("control_request"),
            "request_id": .string(id),
            "request": .object(body)
        ])
    }

    private static func line(_ object: [String: JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
