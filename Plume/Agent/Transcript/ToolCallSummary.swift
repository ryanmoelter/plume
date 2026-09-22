import Foundation

/// A tool call's collapsed one-liner: the tool's name, and the one detail it
/// carries beside it.
///
/// Two fields rather than a formatted string, because the halves render
/// differently — the name as prose, a code-shaped detail in monospace.
/// `ToolCallRow` builds the styled text; nothing here knows a font.
nonisolated struct ToolCallSummary: Equatable {
    /// Whether the detail is a machine token the user could type back — a
    /// command, a path, a pattern — or human prose that would read badly in
    /// monospace.
    nonisolated enum DetailStyle: Equatable {
        case code
        case prose
    }

    private static let maxDetailLength = 60

    let name: String
    /// Already elided to `maxDetailLength`, without a marker: the row draws
    /// it on one line and truncates what does not fit.
    let detail: String?
    let detailStyle: DetailStyle

    init(name: String, detail: String? = nil, detailStyle: DetailStyle = .code) {
        self.name = name
        self.detail = detail
        self.detailStyle = detailStyle
    }

    init(name: String, input: [String: JSONValue]) {
        self.name = name
        guard let detail = Self.detail(name: name, input: input) else {
            self.detail = nil
            self.detailStyle = .prose
            return
        }
        self.detail = Self.elide(detail.text)
        self.detailStyle = detail.style
    }

    /// The one-liner as plain text, for anywhere that cannot carry fonts.
    var plainText: String {
        guard let detail else { return name }
        return "\(name): \(detail)…"
    }

    private static func detail(
        name: String,
        input: [String: JSONValue]
    ) -> (text: String, style: DetailStyle)? {
        switch name {
        case "Bash":
            guard let command = input["command"]?.stringValue else { return nil }
            let firstLine = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
            return (firstLine, .code)
        case "Read", "Write", "Edit":
            guard let path = input["file_path"]?.stringValue else { return nil }
            return ((path as NSString).lastPathComponent, .code)
        case "Grep", "Glob":
            guard let pattern = input["pattern"]?.stringValue else { return nil }
            return (pattern, .code)
        case "Agent":
            let subagentType = input["subagent_type"]?.stringValue ?? "?"
            let description = input["description"]?.stringValue ?? ""
            return ("\(subagentType): \(description)", .prose)
        case "Skill":
            guard let skill = input["skill"]?.stringValue else { return nil }
            return (skill, .code)
        case "WebFetch":
            guard let urlString = input["url"]?.stringValue else { return nil }
            return (URL(string: urlString)?.host ?? urlString, .code)
        default:
            return nil
        }
    }

    private static func elide(_ text: String) -> String {
        guard text.count > maxDetailLength else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: maxDetailLength)
        return String(text[..<cutoff])
    }
}

/// Decides how a tool call's raw input should render. Bash's full, unelided
/// `command` renders as shell code, an `Edit` or `Write` as the change it
/// makes; every other tool keeps the pretty-printed JSON.
nonisolated enum ToolCallInputRendering {
    static func render(name: String, input: [String: JSONValue], prettyJSON: String) -> ToolCallInput {
        if name == "Bash", let command = input["command"]?.stringValue {
            return .code(language: "sh", text: command)
        }
        if let diff = FileDiffBuilder.diff(name: name, input: input) {
            return .diff(diff)
        }
        return .json(prettyJSON)
    }
}
