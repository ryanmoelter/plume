import Testing
import Foundation
import GhosttyTerminal
import GhosttyTheme
@testable import Plume

struct GhosttyThemeResolverTests {
    // MARK: - parseThemeDirective

    @Test func plainThemeAppliesToBothModes() {
        let names = GhosttyThemeResolver.parseThemeDirective("theme = Dracula")
        #expect(names == .init(light: "Dracula", dark: "Dracula"))
    }

    @Test func splitThemeParsesEachMode() {
        let names = GhosttyThemeResolver.parseThemeDirective(
            #"theme = dark:"Lum dark",light:"Lum light""#
        )
        #expect(names == .init(light: "Lum light", dark: "Lum dark"))
    }

    @Test func splitThemeToleratesModeOrderAndSpacing() {
        let names = GhosttyThemeResolver.parseThemeDirective(
            #"theme = light: "One" , dark: "Two""#
        )
        #expect(names == .init(light: "One", dark: "Two"))
    }

    @Test func missingThemeDirectiveReturnsNil() {
        let names = GhosttyThemeResolver.parseThemeDirective("font-family = \"Cascadia Code\"")
        #expect(names == nil)
    }

    @Test func lastThemeLineWins() {
        let names = GhosttyThemeResolver.parseThemeDirective("""
        theme = First
        theme = Second
        """)
        #expect(names == .init(light: "Second", dark: "Second"))
    }

    @Test func commentedThemeLineIsIgnored() {
        let names = GhosttyThemeResolver.parseThemeDirective("""
        # theme = Ignored
        theme = Real
        """)
        #expect(names == .init(light: "Real", dark: "Real"))
    }

    // MARK: - parseThemeFile

    @Test func parsesThemeFileWithHashPrefixedPalette() {
        let contents = """
        palette = 0=#ccc2ba
        palette = 1=#ae3d62
        background = fffbf7
        foreground = 4e463f
        cursor-color = 4e463f
        selection-background = f6ece4
        selection-foreground = 4e463f
        """
        let theme = GhosttyThemeResolver.parseThemeFile(name: "Lum light", contents: contents)
        #expect(theme?.name == "Lum light")
        #expect(theme?.background == "fffbf7")
        #expect(theme?.foreground == "4e463f")
        #expect(theme?.cursorColor == "4e463f")
        #expect(theme?.selectionBackground == "f6ece4")
        #expect(theme?.selectionForeground == "4e463f")
        #expect(theme?.palette[0] == "ccc2ba")
        #expect(theme?.palette[1] == "ae3d62")
    }

    @Test func themeFileWithoutBackgroundOrForegroundFailsToParse() {
        let theme = GhosttyThemeResolver.parseThemeFile(name: "Broken", contents: "palette = 0=#000000")
        #expect(theme == nil)
    }

    @Test func themeFileIgnoresUnknownKeysAndComments() {
        let contents = """
        # a comment
        unknown-key = value
        background = 101010
        foreground = f0f0f0
        """
        let theme = GhosttyThemeResolver.parseThemeFile(name: "Custom", contents: contents)
        #expect(theme?.background == "101010")
        #expect(theme?.foreground == "f0f0f0")
    }

    // MARK: - resolveTheme

    @Test func resolvesCustomThemeFilesForBothModes() {
        let lightContents = "background = fffbf7\nforeground = 4e463f\n"
        let darkContents = "background = 211a14\nforeground = f6ece4\n"

        let theme = GhosttyThemeResolver.resolveTheme(
            configContents: #"theme = dark:"Lum dark",light:"Lum light""#,
            userThemesDirectory: "/fake/themes"
        ) { path in
            switch path {
            case "/fake/themes/Lum light": lightContents
            case "/fake/themes/Lum dark": darkContents
            default: nil
            }
        }

        let expectedLight = GhosttyThemeDefinition(
            name: "Lum light", background: "fffbf7", foreground: "4e463f"
        ).toTerminalConfiguration()
        let expectedDark = GhosttyThemeDefinition(
            name: "Lum dark", background: "211a14", foreground: "f6ece4"
        ).toTerminalConfiguration()

        #expect(theme?.light == expectedLight)
        #expect(theme?.dark == expectedDark)
    }

    @Test func resolvesBuiltInCatalogThemeByName() {
        let theme = GhosttyThemeResolver.resolveTheme(
            configContents: "theme = Dracula",
            userThemesDirectory: "/fake/themes"
        ) { _ in nil }

        let expected = GhosttyThemeCatalog.theme(named: "Dracula")?.toTerminalConfiguration()
        #expect(theme?.light == expected)
        #expect(theme?.dark == expected)
    }

    @Test func unresolvableThemeNameReturnsNil() {
        let theme = GhosttyThemeResolver.resolveTheme(
            configContents: "theme = Nonexistent Theme Name",
            userThemesDirectory: "/fake/themes"
        ) { _ in nil }

        #expect(theme == nil)
    }

    @Test func missingThemeDirectiveResolvesToNil() {
        let theme = GhosttyThemeResolver.resolveTheme(
            configContents: "font-family = \"Cascadia Code\"",
            userThemesDirectory: "/fake/themes"
        ) { _ in nil }

        #expect(theme == nil)
    }

    // MARK: - resolveDefinitions

    @Test func resolveDefinitionsReturnsRawHexForBothModes() {
        let lightContents = "background = fffbf7\nforeground = 4e463f\n"
        let darkContents = "background = 211a14\nforeground = f6ece4\n"

        let definitions = GhosttyThemeResolver.resolveDefinitions(
            configContents: #"theme = dark:"Lum dark",light:"Lum light""#,
            userThemesDirectory: "/fake/themes"
        ) { path in
            switch path {
            case "/fake/themes/Lum light": lightContents
            case "/fake/themes/Lum dark": darkContents
            default: nil
            }
        }

        #expect(definitions?.light?.background == "fffbf7")
        #expect(definitions?.dark?.background == "211a14")
    }

    @Test func resolveDefinitionsReturnsNilWithoutThemeDirective() {
        let definitions = GhosttyThemeResolver.resolveDefinitions(
            configContents: "font-family = \"Cascadia Code\"",
            userThemesDirectory: "/fake/themes"
        ) { _ in nil }

        #expect(definitions == nil)
    }

    @Test func singleNameAppliesToBothModesWhenSplitFormOmitsOne() {
        let contents = "background = 101010\nforeground = f0f0f0\n"
        let theme = GhosttyThemeResolver.resolveTheme(
            configContents: #"theme = dark:"Custom""#,
            userThemesDirectory: "/fake/themes"
        ) { path in
            path == "/fake/themes/Custom" ? contents : nil
        }

        let expected = GhosttyThemeDefinition(
            name: "Custom", background: "101010", foreground: "f0f0f0"
        ).toTerminalConfiguration()

        #expect(theme?.light == expected)
        #expect(theme?.dark == expected)
    }

    @Test func plainThemeValueStripsSurroundingQuotes() {
        let names = GhosttyThemeResolver.parseThemeDirective(#"theme = "Nord""#)
        #expect(names == GhosttyThemeResolver.ThemeNames(light: "Nord", dark: "Nord"))
    }
}
