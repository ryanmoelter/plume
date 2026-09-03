import Foundation

/// Reads Claude Code's own record of which directories the user has accepted
/// the folder-trust prompt for, from `~/.claude.json`'s
/// `projects.<absolute path>.hasTrustDialogAccepted`.
///
/// Side-effect free by design: this never writes the flag. Launching into an
/// untrusted directory must fall back to a transport that can show the real
/// prompt, not silently grant the trust it exists to ask for.
nonisolated enum ClaudeTrustStore {
    static var defaultPath: String {
        NSHomeDirectory() + "/.claude.json"
    }

    /// `true` only when the file parses and the path's entry explicitly says
    /// so. A missing file, a missing entry, or malformed JSON all read as
    /// untrusted — the safe default, since each one means the real answer is
    /// unknown.
    static func isTrusted(_ path: String, claudeJSONPath: String = defaultPath) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJSONPath) else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let projects = root["projects"] as? [String: Any] else { return false }
        guard let entry = projects[path] as? [String: Any] else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool ?? false
    }
}
