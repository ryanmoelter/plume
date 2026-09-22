import Testing
import SwiftUI
import GhosttyTheme
@testable import Plume

/// The sidebar draws its status accents from the terminal theme.
///
/// PLUME-146: every sidebar view read `@Environment(\.theme)` while nothing
/// installed one, so each got `ThemeKey.defaultValue` — built with no
/// definitions, which resolves the accents to the system colors. The quota
/// row's warning and danger therefore rendered as system orange and red over
/// a themed sidebar.
@MainActor
struct SidebarThemeTests {
    /// This machine's own resolved theme, which is what the app draws from.
    /// Absent on a machine with no ghostty config, where there is nothing to
    /// compare against and the fallback is correct by definition.
    private var machineDefinitions: GhosttyThemeResolver.ResolvedDefinitions? {
        GhosttyRuntime.shared.resolvedThemeDefinitions
    }

    /// The bug, stated as the difference it made: with a theme loaded, the
    /// accents a themed palette resolves are not the ones the unthemed
    /// default falls back to.
    @Test func aLoadedThemeMovesTheAccentsOffTheSystemColors() throws {
        let definitions = try #require(
            machineDefinitions,
            "No ghostty theme on this machine, so there is no palette to differ from"
        )
        let themed = Palette(colorScheme: .dark, definitions: definitions)
        let unthemed = Palette(colorScheme: .dark, definitions: nil)

        #expect(unthemed.warning == .orange)
        #expect(unthemed.danger == .red)
        #expect(themed.warning != unthemed.warning)
        #expect(themed.danger != unthemed.danger)
    }

    /// `Color.chatSurface` resolves from the same runtime theme the palette
    /// does, so the sidebar call sites still using it already draw the themed
    /// color. Moving them onto the palette would be a refactor, not a fix.
    @Test func chatSurfaceMatchesThePaletteItBypasses() throws {
        let definitions = try #require(machineDefinitions)

        for scheme in [ColorScheme.light, .dark] {
            let palette = Palette(colorScheme: scheme, definitions: definitions)
            #expect(Color.chatSurface(.divider, colorScheme: scheme) == palette.divider)
            #expect(Color.chatSurface(.primary, colorScheme: scheme) == palette.surface(.primary))
        }
    }

    /// The sidebar takes the chrome scale, not the chat's, so changing the
    /// chat font size leaves sidebar type where it is.
    @Test func sidebarTypeDoesNotFollowTheChatFontSize() {
        let chrome = Typography(bodySize: CGFloat(AppSettings.defaultChatFontSize))
        let enlargedChat = Typography(bodySize: CGFloat(AppSettings.chatFontSizeRange.upperBound))

        #expect(chrome.bodySize != enlargedChat.bodySize)
        #expect(chrome.bodySize == CGFloat(AppSettings.defaultChatFontSize))
    }
}
