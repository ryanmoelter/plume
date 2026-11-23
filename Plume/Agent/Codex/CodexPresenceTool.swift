import Foundation

nonisolated enum CodexPresenceTool {
    static let name = "plume_presence"
    static let definition: JSONValue = .object([
        "type": .string("function"),
        "name": .string(name),
        "description": .string("Read this Mac's Plume presence status: awake, asleep, or locked."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    ])

    static func call(_ params: JSONValue, readPresence: () -> Presence.Report = Presence.current) -> JSONValue {
        let namespace = params["namespace"]
        guard (namespace == nil || namespace == .null), params["tool"]?.stringValue == name else {
            return result("Unknown Plume tool.", success: false)
        }
        guard params["arguments"]?.objectValue?.isEmpty == true else {
            return result("plume_presence takes no arguments.", success: false)
        }
        return result(readPresence().state.rawValue, success: true)
    }

    static func result(_ text: String, success: Bool) -> JSONValue {
        .object([
            "success": .bool(success),
            "contentItems": .array([.object(["type": .string("inputText"), "text": .string(text)])])
        ])
    }
}
