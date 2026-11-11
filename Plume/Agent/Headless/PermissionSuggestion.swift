import Foundation

/// One `permission_suggestions` entry on a `can_use_tool` request: a rule,
/// mode or folder grant the CLI offers to apply alongside an allow.
///
/// Accepting one echoes `raw` back in `updatedPermissions` unchanged, so a
/// field Plume does not model still reaches the CLI. Only the update types
/// that widen what the session may do are offered; the rest are dropped.
nonisolated struct PermissionSuggestion: Equatable, Identifiable {
    struct Rule: Equatable {
        let toolName: String
        let ruleContent: String?
    }

    enum Kind: Equatable {
        case allowRules([Rule])
        case setMode(String)
        case addDirectories([String])
    }

    /// The suggestion's position in the request, which is unique within it.
    let id: Int
    let kind: Kind
    /// `session`, `localSettings`, `projectSettings`, `userSettings` or
    /// `cliArg`. Anything but `session` and `cliArg` is written to a
    /// settings file and outlives the process.
    let destination: String
    let raw: JSONValue

    static func decoding(_ value: JSONValue?, suppressingRules: Bool = false) -> [PermissionSuggestion] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.enumerated().compactMap { index, entry in
            guard let object = entry.objectValue,
                  let kind = kind(of: object, suppressingRules: suppressingRules)
            else { return nil }
            return PermissionSuggestion(
                id: index,
                kind: kind,
                destination: object["destination"]?.stringValue ?? "session",
                raw: entry
            )
        }
    }

    private static func kind(of object: [String: JSONValue], suppressingRules: Bool) -> Kind? {
        switch object["type"]?.stringValue {
        case "addRules":
            guard !suppressingRules, object["behavior"]?.stringValue == "allow" else { return nil }
            let rules = (object["rules"]?.arrayValue ?? []).compactMap { rule -> Rule? in
                guard let toolName = rule.objectValue?["toolName"]?.stringValue else { return nil }
                return Rule(toolName: toolName, ruleContent: rule.objectValue?["ruleContent"]?.stringValue)
            }
            return rules.isEmpty ? nil : .allowRules(rules)
        case "setMode":
            return object["mode"]?.stringValue.map(Kind.setMode)
        case "addDirectories":
            let directories = (object["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            return directories.isEmpty ? nil : .addDirectories(directories)
        default:
            return nil
        }
    }

    var persistsBeyondSession: Bool {
        !["session", "cliArg"].contains(destination)
    }

    /// The button title.
    var label: String {
        switch kind {
        case .allowRules(let rules):
            return "Always allow \(rules.map(Self.describe).joined(separator: ", "))\(scopeSuffix)"
        case .setMode(let mode):
            if mode == PermissionMode.acceptEdits.token, !persistsBeyondSession {
                return "Allow all edits this session"
            }
            let name = PermissionMode.recognizing(mode)?.label ?? mode
            return "Allow and switch to \(name)\(scopeSuffix)"
        case .addDirectories(let directories):
            let names = directories.map { ($0 as NSString).abbreviatingWithTildeInPath }
            return "Allow access to \(names.joined(separator: ", "))\(scopeSuffix)"
        }
    }

    /// Where an accepted suggestion is kept, for the button's tooltip.
    var detail: String {
        switch destination {
        case "localSettings": "Saved to this project's .claude/settings.local.json"
        case "projectSettings": "Saved to this project's .claude/settings.json, which is shared"
        case "userSettings": "Saved to ~/.claude/settings.json, for every project"
        default: "Applies until this conversation's process exits"
        }
    }

    private var scopeSuffix: String {
        switch destination {
        case "localSettings", "projectSettings": " in this project"
        case "userSettings": " everywhere"
        default: " this session"
        }
    }

    private static func describe(_ rule: Rule) -> String {
        guard let content = rule.ruleContent, !content.isEmpty else { return rule.toolName }
        return rule.toolName == "Bash" ? "“\(content)”" : "\(rule.toolName)(\(content))"
    }
}
