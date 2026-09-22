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

    /// Whether Claude Code will run in `path` without asking.
    ///
    /// Trust is inherited: the CLI prompts for a directory only when neither
    /// it nor any ancestor has been accepted, and it records nothing for the
    /// nested directory afterwards. Probing the real CLI in a fresh folder
    /// under a trusted repository confirms both halves — it answers normally
    /// and leaves no `projects` entry behind. An exact-path lookup therefore
    /// calls every worktree under `<repo>/.plume/worktrees` untrusted.
    ///
    /// The nearest ancestor with an explicit flag wins, so a directory the
    /// user declined stays untrusted even inside a trusted parent. A missing
    /// file, no entry anywhere up the chain, or malformed JSON all read as
    /// untrusted — each means the real answer is unknown.
    static func isTrusted(_ path: String, claudeJSONPath: String = defaultPath) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJSONPath) else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let projects = root["projects"] as? [String: Any] else { return false }

        for candidate in selfAndAncestors(of: path) {
            guard let entry = projects[candidate] as? [String: Any],
                  let accepted = entry["hasTrustDialogAccepted"] as? Bool
            else { continue }
            return accepted
        }
        return false
    }

    /// `path` and every directory above it, nearest first.
    static func selfAndAncestors(of path: String) -> [String] {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var result = [url.path]
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            result.append(url.path)
        }
        return result
    }
}
