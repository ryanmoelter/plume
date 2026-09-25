import AppKit
import SwiftUI

/// Tints the Settings window with the terminal theme, the way `ThemeChrome`
/// tints the main window, and makes it resizable. The `Settings` scene builds
/// a fixed-size window whatever its `windowResizability`, and SwiftUI clears
/// `.resizable` again after the window appears, so `ResizableLock` puts it
/// back each time.
struct SettingsWindowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: NSWindow?
    @State private var resizableLock = ResizableLock()

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
            .onChange(of: GhosttyRuntime.shared.resolvedThemeDefinitions) { configure() }
    }

    private func configure() {
        guard let window else { return }
        resizableLock.hold(window)
        let tint = ThemeChrome.titlebarBackground()
        window.titlebarAppearsTransparent = tint != nil
        window.backgroundColor = tint
    }
}

@MainActor
private final class ResizableLock {
    private var observation: NSKeyValueObservation?

    func hold(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        observation = window.observe(\.styleMask) { window, _ in
            MainActor.assumeIsolated {
                if !window.styleMask.contains(.resizable) {
                    window.styleMask.insert(.resizable)
                }
            }
        }
    }
}
