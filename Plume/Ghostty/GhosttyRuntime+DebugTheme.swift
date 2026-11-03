#if DEBUG
import Foundation
import GhosttyTheme

/// Recolors Plume's own chrome with any theme Ghostty.app ships, leaving the
/// terminals on the config's theme.
extension GhosttyRuntime {
    private static let debugThemeOverrideKey = "PlumeDebugThemeOverride"
    private static let debugThemesDirectory = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"

    /// Ghostty.app's theme names, sorted; empty when it is not installed.
    static func debugThemeNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: debugThemesDirectory)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var debugThemeOverrideName: String? {
        UserDefaults.standard.string(forKey: Self.debugThemeOverrideKey)
    }

    func setDebugThemeOverride(_ name: String?) {
        UserDefaults.standard.set(name, forKey: Self.debugThemeOverrideKey)
        adoptChromeTheme()
    }

    static func debugThemeOverride() -> GhosttyThemeResolver.ResolvedDefinitions? {
        guard
            let name = UserDefaults.standard.string(forKey: debugThemeOverrideKey),
            let contents = try? String(contentsOfFile: "\(debugThemesDirectory)/\(name)", encoding: .utf8),
            let definition = GhosttyThemeResolver.parseThemeFile(name: name, contents: contents)
        else { return nil }
        return GhosttyThemeResolver.ResolvedDefinitions(light: definition, dark: definition)
    }
}
#endif
