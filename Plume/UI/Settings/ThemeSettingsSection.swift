import SwiftUI

/// Where the app's colors come from. The theme is read once at launch, so
/// this reports what `GhosttyRuntime` resolved then.
struct ThemeSettingsSection: View {
    private let runtime = GhosttyRuntime.shared

    var body: some View {
        Section {
            LabeledContent("Theme") {
                Text(themeDescription)
                    .foregroundStyle(.secondary)
            }
            if let path = runtime.loadedConfigPath {
                LabeledContent("Ghostty config") {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text("\(AppIdentity.displayName) takes its theme from your Ghostty config. Restart \(AppIdentity.displayName) after you change it.")
                .foregroundStyle(.secondary)
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
            .joined(separator: ", ")
    }
}
