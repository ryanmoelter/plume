#if DEBUG
import AppKit
import SwiftUI

/// Tints the Settings window with the terminal theme, the way `ThemeChrome`
/// tints the main window. Debug-only while it is tried out.
struct SettingsThemeModifier: ViewModifier {
    static let key = "debugThemesSettingsWindow"

    @AppStorage(Self.key) private var isEnabled = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        let background = isEnabled ? ThemeChrome.background(for: colorScheme) : nil
        let foreground = ThemeChrome.foreground(for: colorScheme)
        content
            .scrollContentBackground(background == nil ? .automatic : .hidden)
            .background(background ?? .clear)
            .foregroundStyle(background == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(foreground ?? .primary))
            .background {
                WindowProbe { newWindow in
                    if window !== newWindow { window = newWindow }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: window) { tintTitlebar() }
            .onChange(of: isEnabled) { tintTitlebar() }
    }

    private func tintTitlebar() {
        guard let window else { return }
        let tint = isEnabled ? ThemeChrome.titlebarBackground() : nil
        window.titlebarAppearsTransparent = tint != nil
        window.backgroundColor = tint
    }
}
#endif
