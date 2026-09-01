import Foundation
import GhosttyTerminal
import GhosttyTheme

/// Resolves a ghostty config's `theme = ...` directive into an actual
/// `TerminalTheme`.
///
/// The wrapper renders its own config rather than calling
/// `ghostty_config_load_default_files` (see `GhosttyConfigLoader`), and its
/// embedded `GHOSTTY_RESOURCES_DIR` (`GhosttyRuntimeResources`) ships only
/// `shell-integration/` — no `themes/` directory. So a bare `theme = Name`
/// line in the user's config is not resolvable by libghostty itself: it is
/// silently accepted (no diagnostic) and the surface falls back to default
/// colors. Name resolution has to happen here, in Swift, the same way the
/// package's own docs describe applying a theme:
/// `GhosttyThemeCatalog.theme(named:)` for built-ins, or a directory of
/// per-name files (`~/.config/ghostty/themes/<name>`, ghostty's own
/// convention) for a user's custom themes.
enum GhosttyThemeResolver {
    /// One resolved theme name per color scheme, as parsed from a `theme =`
    /// config line.
    struct ThemeNames: Equatable {
        var light: String?
        var dark: String?

        var isEmpty: Bool { light == nil && dark == nil }
    }

    /// Reads `configContents` for its last `theme = ...` line and resolves
    /// the named theme(s) against the built-in catalog, then a directory of
    /// user theme files. Returns nil if no `theme` directive is present or
    /// neither name resolves to anything.
    static func resolveTheme(
        configContents: String,
        userThemesDirectory: String,
        readThemeFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> TerminalTheme? {
        guard let names = parseThemeDirective(configContents), !names.isEmpty else {
            return nil
        }

        let light = names.light.flatMap {
            resolveDefinition($0, userThemesDirectory: userThemesDirectory, readThemeFile: readThemeFile)
        }
        let dark = names.dark.flatMap {
            resolveDefinition($0, userThemesDirectory: userThemesDirectory, readThemeFile: readThemeFile)
        }

        guard light != nil || dark != nil else { return nil }

        // A theme naming only one mode reuses that definition for the other,
        // matching ghostty's own single-name `theme = X` behavior.
        let resolvedLight = light ?? dark
        let resolvedDark = dark ?? light

        return TerminalTheme(
            light: resolvedLight?.toTerminalConfiguration() ?? .init(),
            dark: resolvedDark?.toTerminalConfiguration() ?? .init()
        )
    }

    /// Parses ghostty's `theme` directive value, in either the plain
    /// `theme = Name` form or the split `theme = dark:"X",light:"Y"` form.
    /// Ghostty takes the last occurrence of a repeated key, so this does too.
    static func parseThemeDirective(_ configContents: String) -> ThemeNames? {
        var lastValue: String?

        for rawLine in configContents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "theme" else { continue }

            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            lastValue = value
        }

        guard let value = lastValue else { return nil }
        return parseThemeValue(value)
    }

    private static func parseThemeValue(_ value: String) -> ThemeNames {
        guard value.contains(":") else {
            return ThemeNames(light: value, dark: value)
        }

        var names = ThemeNames()
        for component in value.split(separator: ",") {
            let pair = component.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let mode = pair[0].trimmingCharacters(in: .whitespaces)
            let name = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            guard !name.isEmpty else { continue }

            switch mode {
            case "light": names.light = name
            case "dark": names.dark = name
            default: break
            }
        }
        return names
    }

    private static func resolveDefinition(
        _ name: String,
        userThemesDirectory: String,
        readThemeFile: (String) -> String?
    ) -> GhosttyThemeDefinition? {
        if let builtIn = GhosttyThemeCatalog.theme(named: name) {
            return builtIn
        }

        let path = "\(userThemesDirectory)/\(name)"
        guard let contents = readThemeFile(path) else { return nil }
        return parseThemeFile(name: name, contents: contents)
    }

    /// Parses a ghostty theme file: `key = value` lines, `palette = N=#rrggbb`
    /// repeated per index, colors optionally `#`-prefixed.
    static func parseThemeFile(name: String, contents: String) -> GhosttyThemeDefinition? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "background": background = stripHash(value)
            case "foreground": foreground = stripHash(value)
            case "cursor-color": cursorColor = stripHash(value)
            case "cursor-text": cursorText = stripHash(value)
            case "selection-background": selectionBackground = stripHash(value)
            case "selection-foreground": selectionForeground = stripHash(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                palette[index] = stripHash(parts[1].trimmingCharacters(in: .whitespaces))
            default:
                continue
            }
        }

        guard let background, let foreground else { return nil }

        return GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    private static func stripHash(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()) : value
    }
}
