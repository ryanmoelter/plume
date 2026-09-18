import Foundation
import SwiftUI
import os

/// Finds the user's own ghostty config so embedded terminals inherit their
/// theme, font, and keybinds.
///
/// The wrapper renders a config file rather than calling
/// `ghostty_config_load_default_files`, so discovery is ours to do. This
/// mirrors ghostty's own search order, and follows the `config-file`
/// directive the same way ghostty does.
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
    /// resolving symlinks first — the Application Support config is often a
    /// symlink to the real XDG config, and themes live next to the target,
    /// not next to the symlink.
    ///
    /// Callers should pass the path of the file that declared the winning
    /// `theme` directive (`winningThemeSourcePath(in:)`), not the discovered
    /// root config: a root that only redirects via `config-file` has no
    /// `themes/` of its own.
    static func themesDirectory(forConfigPath configPath: String) -> String {
        let resolved = URL(fileURLWithPath: configPath).resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().appendingPathComponent("themes").path
    }

    // MARK: - config-file expansion

    /// One config line, tagged with the file it came from.
    struct ExpandedLine: Equatable {
        let sourcePath: String
        let content: String
    }

    /// A config with every `config-file` include followed, flattened into
    /// ghostty's effective directive order.
    struct ExpandedConfig: Equatable {
        let lines: [ExpandedLine]

        var rawContents: String { lines.map(\.content).joined(separator: "\n") }
    }

    /// Reads `rootPath` and every config it includes, in the order ghostty
    /// applies them. Returns nil only when the root itself is unreadable.
    ///
    /// A `config-file` that is missing, cyclic, or nested past `maxDepth` is
    /// skipped rather than failing the load, so a stale include still leaves
    /// the user with the rest of their config.
    static func expandConfig(
        rootPath: String,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        maxDepth: Int = 10
    ) -> ExpandedConfig? {
        guard let contents = readFile(rootPath) else { return nil }

        return ExpandedConfig(lines: expand(
            contents: contents,
            path: rootPath,
            openPaths: [canonicalPath(rootPath)],
            depth: 0,
            maxDepth: maxDepth,
            readFile: readFile
        ))
    }

    /// The file that declared the `theme` ghostty would end up using — the
    /// last one in expansion order, matching ghostty's last-wins semantics.
    static func winningThemeSourcePath(in expanded: ExpandedConfig) -> String? {
        expanded.lines.last { directiveValue(in: $0.content, key: "theme") != nil }?.sourcePath
    }

    /// The `font-family` ghostty would end up using: the last directive in
    /// expansion order, matching ghostty's last-wins semantics for a repeated
    /// key. An include applies after the file that named it, so a value set
    /// there beats one set earlier in the including file — the same ordering
    /// `winningThemeSourcePath` relies on.
    static func resolvedFontFamily(in expanded: ExpandedConfig) -> String? {
        expanded.lines
            .compactMap { directiveValue(in: $0.content, key: "font-family") }
            .last
            .map(unquoted)
    }

    /// The `font-weight` ghostty would end up using, last-wins like
    /// `resolvedFontFamily`.
    ///
    /// ghostty takes either a name or a number, so both are read. A value it
    /// would reject is ignored rather than guessed at, leaving the face's own
    /// regular weight.
    static func resolvedFontWeight(in expanded: ExpandedConfig) -> Font.Weight? {
        expanded.lines
            .compactMap { directiveValue(in: $0.content, key: "font-weight") }
            .last
            .map(unquoted)
            .flatMap(fontWeight)
    }

    /// ghostty's weight names, plus the numeric form it also accepts. The
    /// numbers are the CSS scale, which is what `Font.Weight`'s cases name.
    private static func fontWeight(_ value: String) -> Font.Weight? {
        switch value.lowercased() {
        case "thin", "100": .thin
        case "extralight", "extra-light", "200": .ultraLight
        case "light", "300": .light
        case "regular", "normal", "400": .regular
        case "medium", "500": .medium
        case "semibold", "semi-bold", "600": .semibold
        case "bold", "700": .bold
        case "extrabold", "extra-bold", "800": .heavy
        case "black", "900": .black
        default: nil
        }
    }

    /// The expanded config with `theme` and `config-file` removed, ready to
    /// hand to libghostty as generated contents.
    ///
    /// `GhosttyThemeResolver` resolves `theme` in Swift and the result reaches
    /// the controller as a `TerminalTheme`, so libghostty never needs to see
    /// it — and must not. Its embedded resources ship no `themes/` directory,
    /// so the line resolves to nothing anyway, and a split
    /// `theme = dark:X,light:Y` naming *different* themes actively breaks
    /// terminal launching: ghostty's `finalize()` marks the config conditional
    /// on theme, so building a surface rebuilds the config from defaults and
    /// replays only file-derived settings. The per-surface `command` is set
    /// directly on the struct rather than replayed, so it is dropped and the
    /// surface silently spawns a login shell. `finalize()` preserves
    /// `working-directory` across that rebuild but not `command`, which is why
    /// only `command` goes missing. No diagnostic is reported: it lands on the
    /// discarded config.
    ///
    /// `config-file` goes too because expansion has already inlined the target.
    /// Leaving it in would make libghostty resolve the path a second time,
    /// against generated contents that have no directory to be relative to.
    static func flattenedContentsForGhostty(_ expanded: ExpandedConfig) -> String {
        strippingDirectives(from: expanded.rawContents, keys: ["theme", "config-file"])
    }

    static func strippingThemeDirectives(from contents: String) -> String {
        strippingDirectives(from: contents, keys: ["theme"])
    }

    private static func strippingDirectives(from contents: String, keys: Set<String>) -> String {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
                    return true
                }
                let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
                return !keys.contains(key)
            }
            .joined(separator: "\n")
    }

    private static func expand(
        contents: String,
        path: String,
        openPaths: Set<String>,
        depth: Int,
        maxDepth: Int,
        readFile: (String) -> String?
    ) -> [ExpandedLine] {
        var lines: [ExpandedLine] = []
        var includes: [String] = []

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let value = directiveValue(in: line, key: "config-file") {
                includes.append(value)
            } else {
                lines.append(ExpandedLine(sourcePath: path, content: line))
            }
        }

        // Ghostty loads an included file after the whole file that named it,
        // not at the point of the directive, so an included value beats one
        // set later in the including file. Appending here reproduces that.
        for value in includes {
            lines += expandInclude(
                value,
                includedFrom: path,
                openPaths: openPaths,
                depth: depth,
                maxDepth: maxDepth,
                readFile: readFile
            )
        }

        return lines
    }

    private static func expandInclude(
        _ value: String,
        includedFrom path: String,
        openPaths: Set<String>,
        depth: Int,
        maxDepth: Int,
        readFile: (String) -> String?
    ) -> [ExpandedLine] {
        let (target, isOptional) = includeTarget(value, includedFrom: path)
        guard !target.isEmpty else { return [] }

        guard depth < maxDepth else {
            Log.ghostty.error("Ghostty config-file nested too deeply, skipping \(target, privacy: .public)")
            return []
        }

        let canonical = canonicalPath(target)
        guard !openPaths.contains(canonical) else {
            Log.ghostty.error("Ghostty config-file cycle detected, skipping \(target, privacy: .public)")
            return []
        }

        guard let contents = readFile(target) else {
            if !isOptional {
                Log.ghostty.error("Ghostty config-file could not be read: \(target, privacy: .public)")
            }
            return []
        }

        return expand(
            contents: contents,
            path: target,
            openPaths: openPaths.union([canonical]),
            depth: depth + 1,
            maxDepth: maxDepth,
            readFile: readFile
        )
    }

    /// Resolves a `config-file` value the way ghostty documents it: a leading
    /// `?` marks the include optional, `~` expands, and a relative path is
    /// relative to the file that named it rather than to the root config.
    static func includeTarget(
        _ value: String,
        includedFrom path: String
    ) -> (path: String, isOptional: Bool) {
        var raw = unquoted(value)
        let isOptional = raw.hasPrefix("?")
        if isOptional {
            raw = unquoted(String(raw.dropFirst()))
        }
        guard !raw.isEmpty else { return ("", isOptional) }

        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return (expanded, isOptional) }

        let directory = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return (directory.appendingPathComponent(expanded).path, isOptional)
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    /// The value `line` assigns to `key`, or nil if it assigns something else,
    /// is a comment, or is blank.
    private static func directiveValue(in line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        guard trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == key else {
            return nil
        }
        return String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
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
