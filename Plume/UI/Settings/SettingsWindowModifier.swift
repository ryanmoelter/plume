import AppKit
import SwiftUI

/// Tints the Settings window with the terminal theme, the way `ThemeChrome`
/// tints the main window, and makes it resizable — the `Settings` scene
/// builds a fixed-size window whatever its `windowResizability`.
struct SettingsWindowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        let background = ThemeChrome.background(for: colorScheme)
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
            .onChange(of: window) { configure() }
    }

    private func configure() {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        let tint = ThemeChrome.titlebarBackground()
        window.titlebarAppearsTransparent = tint != nil
        window.backgroundColor = tint
    }
}
