import GhosttyTheme
import SwiftUI

/// Where the app's colors come from, as `GhosttyRuntime` last resolved them.
struct ThemeSettingsSection: View {
    private let runtime = GhosttyRuntime.shared
    @State private var settings = AppSettings.shared
    @State private var showsOtherPalette = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            LabeledContent {
                VStack(alignment: .trailing) {
                    Text(themeDescription)
                        .foregroundStyle(.secondary)
                    Button("Reload", action: runtime.reloadTheme)
                        .plumeID(AccessibilityID.settingsThemeReloadButton, invoke: runtime.reloadTheme)
                }
            } label: {
                Text("Theme")
                Text("Read from Ghostty config")
                    .foregroundStyle(.secondary)
            }
            if let path = runtime.loadedConfigPath {
                LabeledContent("Ghostty config path") {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Toggle("Use extended color palette", isOn: $settings.usesExtendedPalette)
            .plumeID(
                AccessibilityID.settingsExtendedPaletteToggle,
                value: settings.usesExtendedPalette ? "on" : "off",
                invoke: { settings.usesExtendedPalette.toggle() }
            )
            LabeledContent {
                Text(settings.accentTint?.name(lum: runtime.extendedPalette?.isLum == true) ?? "System")
                    .foregroundStyle(.secondary)
            } label: {
                Text("Accent color")
                Text("Click a color below to use it")
                    .foregroundStyle(.secondary)
            }
            let palettes = palettes
            if let current = palettes.first {
                paletteView(current)
            }
            if palettes.count > 1 {
                let other = palettes[1]
                Button("\(showsOtherPalette ? "Hide" : "Show") \(other.label) palette") {
                    showsOtherPalette.toggle()
                }
                .plumeID(
                    AccessibilityID.settingsOtherPaletteButton,
                    value: showsOtherPalette ? "shown" : "hidden",
                    invoke: { showsOtherPalette.toggle() }
                )
                if showsOtherPalette {
                    paletteView(other)
                }
            }
        } header: {
            Text("Theme")
        }
    }

    private typealias ThemePalette = (label: String, definition: GhosttyThemeDefinition, extendedColors: ExtendedPalette.Colors?)

    private func paletteView(_ palette: ThemePalette) -> some View {
        ThemePaletteView(
            definition: palette.definition,
            label: palette.label,
            selection: settings.accentTint,
            extended: settings.usesExtendedPalette || settings.accentTint?.isExtended == true,
            extendedColors: palette.extendedColors,
            onSelect: { settings.accentTint = $0 }
        )
    }

    /// The current appearance's palette then the other one, or just one when
    /// both sides are the same theme.
    private var palettes: [ThemePalette] {
        let definitions = runtime.resolvedThemeDefinitions
        let extended = runtime.extendedPalette
        let light = definitions?.light
        let dark = definitions?.dark
        if let light, let dark, light.name != dark.name {
            let both: [ThemePalette] = [("light", light, extended?.light), ("dark", dark, extended?.dark)]
            return colorScheme == .dark ? both.reversed() : both
        }
        if let light { return [("theme", light, extended?.light)] }
        return dark.map { [("theme", $0, extended?.dark)] } ?? []
    }

    private var themeDescription: String {
        guard runtime.loadedConfigPath != nil else {
            return "No Ghostty config found, so the default theme"
        }
        guard let names = runtime.configThemeNames else {
            return "No theme found in the config, so the default theme"
        }
        let light = names.light
        let dark = names.dark
        if light == dark, let light { return light }
        return [light.map { "\($0) (light)" }, dark.map { "\($0) (dark)" }]
            .compactMap { $0 }
            .joined(separator: " / ")
    }
}
