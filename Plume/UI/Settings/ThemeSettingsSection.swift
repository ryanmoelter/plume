import GhosttyTheme
import SwiftUI

/// Where the app's colors come from, as `GhosttyRuntime` last resolved them.
struct ThemeSettingsSection: View {
    private let runtime = GhosttyRuntime.shared
    @State private var settings = AppSettings.shared

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
            LabeledContent {
                Text(settings.accentPaletteSlot.map { ThemeChrome.paletteSlotNames[$0] } ?? "System")
                    .foregroundStyle(.secondary)
            } label: {
                Text("Accent color")
                Text("Click a color below to use it")
                    .foregroundStyle(.secondary)
            }
            ForEach(palettes, id: \.label) { palette in
                ThemePaletteView(
                    definition: palette.definition,
                    label: palette.label,
                    selectedSlot: settings.accentPaletteSlot,
                    onSelect: { settings.accentPaletteSlot = $0 }
                )
            }
        } header: {
            Text("Theme")
        }
    }

    /// The light palette then the dark one, or just one when both sides are
    /// the same theme.
    private var palettes: [(label: String, definition: GhosttyThemeDefinition)] {
        let definitions = runtime.resolvedThemeDefinitions
        let light = definitions?.light
        let dark = definitions?.dark
        if let light, let dark, light.name != dark.name {
            return [("light", light), ("dark", dark)]
        }
        return (light ?? dark).map { [("theme", $0)] } ?? []
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
