import Foundation

/// How the host answers a `can_use_tool` control request.
enum PermissionDecision: Equatable {
    /// `updatedInput` is the hook for editing a call before it runs, and for
    /// carrying an `AskUserQuestion`'s answers.
    case allow(updatedInput: [String: JSONValue])
    case deny(message: String)
}

/// Builds the NDJSON lines Plume writes to `claude -p`'s stdin.
enum StreamJSONEncoder {
    static func userTurn(text: String) -> String? {
        line([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text)
                ])])
            ])
        ])
    }

    static func initialize(requestID: String) -> String? {
        controlRequest(id: requestID, body: [
            "subtype": .string("initialize"),
            "hooks": .object([:])
        ])
    }

    static func interrupt(requestID: String) -> String? {
        controlRequest(id: requestID, body: ["subtype": .string("interrupt")])
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
