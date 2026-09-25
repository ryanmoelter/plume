import SwiftUI

/// Where the app's colors come from, as `GhosttyRuntime` last resolved them.
struct ThemeSettingsSection: View {
    private let runtime = GhosttyRuntime.shared

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
        } header: {
            Text("Theme")
        }
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
