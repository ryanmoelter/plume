import Foundation

/// Finds the user's own ghostty config so embedded terminals inherit their
/// theme, font, and keybinds.
///
/// The wrapper renders a config file rather than calling
/// `ghostty_config_load_default_files`, so discovery is ours to do. This
/// mirrors ghostty's own search order.
enum GhosttyConfigLoader {
    /// First existing path in ghostty's search order, or nil to fall back to
    /// the wrapper's built-in defaults.
    ///
    /// Ghostty takes the first match outright and never merges, so this stops
    /// at the first hit too.
    static func userConfigPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { isNonEmptyFile(at: $0) }
    ) -> String? {
        candidatePaths(environment: environment).first(where: fileExists)
    }

    /// Mirrors `preferredDefaultFilePath()` in ghostty's `src/config/file_load.zig`:
    /// Application Support outranks XDG on macOS, and `config.ghostty` outranks
    /// the pre-1.3.0 `config` name within each pair.
    static func candidatePaths(environment: [String: String]) -> [String] {
        let home = NSHomeDirectory()
        let appSupport = "\(home)/Library/Application Support/com.mitchellh.ghostty"

        let xdgBase = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        let xdg = "\(xdgBase)/ghostty"

        return [
            "\(appSupport)/config.ghostty",
            "\(appSupport)/config",
            "\(xdg)/config.ghostty",
            "\(xdg)/config",
        ]
    }

    /// The `themes/` directory ghostty looks in alongside a config file,
    /// resolving symlinks first — the Application Support config is a
    /// symlink to the real XDG config, and themes live next to the target,
    /// not next to the symlink.
    static func themesDirectory(forConfigPath configPath: String) -> String {
        let resolved = URL(fileURLWithPath: configPath).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().appendingPathComponent("themes").path
    }

    /// Ghostty rejects zero-byte config files, so an empty file should fall
    /// through to the next candidate rather than win.
    private static func isNonEmptyFile(at path: String) -> Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int
        else { return false }
        return size > 0
    }
}
