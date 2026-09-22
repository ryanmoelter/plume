import Testing
import GhosttyTheme
@testable import Plume

struct AppAppearanceTests {
    @Test func noThemeFollowsSystem() {
        #expect(AppAppearance.decision(for: nil) == .followSystem)
    }

    @Test func singleDarkThemeForcesDarkAppearance() {
        // Light foreground on a dark background: readable only in dark mode.
        let dark = GhosttyThemeDefinition(name: "Night", background: "1a1a1a", foreground: "f0f0f0")
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: dark, dark: dark)
        #expect(AppAppearance.decision(for: definitions) == .forcedDark)
    }

    @Test func singleLightThemeForcesLightAppearance() {
        // Dark foreground on a light background: readable only in light mode.
        let light = GhosttyThemeDefinition(name: "Day", background: "f0f0f0", foreground: "1a1a1a")
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: light, dark: light)
        #expect(AppAppearance.decision(for: definitions) == .forcedLight)
    }

    /// A pair means the config named different themes per mode — each one
    /// already fits its mode, so the app leaves the system in charge.
    @Test func lightDarkPairFollowsSystem() {
        let light = GhosttyThemeDefinition(name: "Day", background: "f0f0f0", foreground: "1a1a1a")
        let dark = GhosttyThemeDefinition(name: "Night", background: "1a1a1a", foreground: "f0f0f0")
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: light, dark: dark)
        #expect(AppAppearance.decision(for: definitions) == .followSystem)
    }

    @Test func unparseableColorsFollowSystem() {
        let broken = GhosttyThemeDefinition(name: "Broken", background: "not-a-color", foreground: "also-bad")
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: broken, dark: broken)
        #expect(AppAppearance.decision(for: definitions) == .followSystem)
    }

    @Test func missingOneSideFollowsSystem() {
        let light = GhosttyThemeDefinition(name: "Day", background: "f0f0f0", foreground: "1a1a1a")
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: light, dark: nil)
        #expect(AppAppearance.decision(for: definitions) == .followSystem)
    }
}
