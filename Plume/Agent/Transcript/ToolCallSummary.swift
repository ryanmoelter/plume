import Foundation

/// Table-driven one-liner for a tool call, formatted as `Name(detail)`.
enum ToolCallSummary {
    private static let maxDetailLength = 60

    static func summary(name: String, input: [String: JSONValue]) -> String {
        guard let detail = detail(name: name, input: input) else { return name }
        return "\(name)(\(elide(detail)))"
    }

    private static func detail(name: String, input: [String: JSONValue]) -> String? {
        switch name {
        case "Bash":
            guard let command = input["command"]?.stringValue else { return nil }
            return command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
        case "Read", "Write", "Edit":
            guard let path = input["file_path"]?.stringValue else { return nil }
            return (path as NSString).lastPathComponent
        case "Grep", "Glob":
            return input["pattern"]?.stringValue
        case "Agent":
            let subagentType = input["subagent_type"]?.stringValue ?? "?"
            let description = input["description"]?.stringValue ?? ""
            return "\(subagentType): \(description)"
        case "Skill":
            return input["skill"]?.stringValue
        case "WebFetch":
            guard let urlString = input["url"]?.stringValue, let host = URL(string: urlString)?.host else {
                return input["url"]?.stringValue
            }
            return host
        default:
            return nil
        }
    }

    private static func elide(_ text: String) -> String {
        guard text.count > maxDetailLength else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: maxDetailLength)
        return "\(text[..<cutoff])…"
    }
}

/// Decides how a tool call's raw input should render. Bash's full,
/// unelided `command` renders as shell code; every other tool keeps the
/// pretty-printed JSON.
enum ToolCallInputRendering {
    static func render(name: String, input: [String: JSONValue], prettyJSON: String) -> ToolCallInput {
        guard name == "Bash" else { return .json(prettyJSON) }
        guard let command = input["command"]?.stringValue else { return .json(prettyJSON) }
        return .code(language: "sh", text: command)
    }
}
