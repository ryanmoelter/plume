import AppKit
import GhosttyTheme

/// Decides whether Plume's own chrome (window, sidebar glass, Settings)
/// should be forced into a fixed appearance, or left to follow the system.
///
/// A single-theme config (`theme = X`) uses the same colors in both light
/// and dark mode, so the system glass has to be forced to match — otherwise
/// a dark theme on a light-mode Mac puts pale glass behind pale text. A
/// light/dark pair already fits its mode in either appearance, so the app
/// follows the system unchanged.
enum AppAppearance {
    enum Decision: Equatable {
        case forcedDark
        case forcedLight
        case followSystem
    }

    /// Reads the live runtime's resolved theme.
    static func decision() -> Decision {
        decision(for: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    /// Testable core: decides from an explicit `ResolvedDefinitions` rather
    /// than the live runtime.
    ///
    /// `light` and `dark` are identical only when the config named one theme
    /// for both modes — `GhosttyThemeResolver.resolveDefinitions` reuses the
    /// single definition for whichever side the config left unset. A pair
    /// that happens to repeat the same name for both modes is
    /// indistinguishable from a single theme, and correctly treated the same
    /// way: its colors already fit both appearances.
    static func decision(
        for definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> Decision {
        guard let definitions, let light = definitions.light, let dark = definitions.dark,
              light == dark
        else {
            return .followSystem
        }

        guard
            let backgroundRGB = HexRGB(hex: light.background),
            let foregroundRGB = HexRGB(hex: light.foreground)
        else {
            return .followSystem
        }

        return foregroundRGB.relativeLuminance > backgroundRGB.relativeLuminance
            ? .forcedDark
            : .forcedLight
    }

    /// Applies `decision` app-wide. `nil` tells AppKit to follow the system,
    /// undoing an earlier forced appearance if the theme changed.
    static func apply(_ decision: Decision, to app: NSApplication = .shared) {
        switch decision {
        case .forcedDark: app.appearance = NSAppearance(named: .darkAqua)
        case .forcedLight: app.appearance = NSAppearance(named: .aqua)
        case .followSystem: app.appearance = nil
        }
    }
}
