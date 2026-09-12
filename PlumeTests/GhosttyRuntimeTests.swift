import Testing
import Foundation
import GhosttyTerminal
import GhosttyTheme
@testable import Plume

@MainActor
struct GhosttyRuntimeTests {
    private static let fallback = GhosttyThemeResolver.ResolvedDefinitions(
        light: GhosttyThemeDefinition(name: "Lum light", background: "fffbf7", foreground: "4e463f"),
        dark: GhosttyThemeDefinition(name: "Lum dark", background: "211a14", foreground: "f6ece4")
    )

    @Test func noThemeDirectiveFallsBackToBundledDefault() {
        let expanded = GhosttyConfigLoader.ExpandedConfig(lines: [
            .init(sourcePath: "/fake/config", content: "font-family = \"Cascadia Code\"")
        ])

        let resolved = GhosttyRuntime.resolveThemeDefinitions(in: expanded, bundledDefault: Self.fallback)
        #expect(resolved == Self.fallback)
    }

    @Test func themeThatResolvesToNothingFallsBackToBundledDefault() {
        let expanded = GhosttyConfigLoader.ExpandedConfig(lines: [
            .init(sourcePath: "/fake/config", content: "theme = DoesNotExist")
        ])

        let resolved = GhosttyRuntime.resolveThemeDefinitions(in: expanded, bundledDefault: Self.fallback)
        #expect(resolved == Self.fallback)
    }

    @Test func userDeclaredThemeStillWinsOverTheBundledDefault() {
        let expanded = GhosttyConfigLoader.ExpandedConfig(lines: [
            .init(sourcePath: "/fake/config", content: "theme = Dracula")
        ])

        let resolved = GhosttyRuntime.resolveThemeDefinitions(in: expanded, bundledDefault: Self.fallback)
        #expect(resolved?.light?.name == "Dracula")
        #expect(resolved?.dark?.name == "Dracula")
        #expect(resolved != Self.fallback)
    }

    @Test func bundledLumDefinitionsLoadFromTheAppBundle() throws {
        let definitions = try #require(GhosttyRuntime.bundledLumDefinitions)
        #expect(definitions.light?.name == "Lum light")
        #expect(definitions.dark?.name == "Lum dark")
        #expect(definitions.light?.background == "fffbf7")
        #expect(definitions.dark?.background == "211a14")
    }
}
