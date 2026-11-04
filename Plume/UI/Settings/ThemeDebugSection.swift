#if DEBUG
import SwiftUI

/// Swaps the theme Plume and its terminals take, without touching the
/// Ghostty config.
struct ThemeDebugSection: View {
    private let runtime = GhosttyRuntime.shared
    @State private var themeNames = GhosttyRuntime.debugThemeNames()
    @State private var override = GhosttyRuntime.shared.debugThemeOverrideName

    var body: some View {
        Section {
            Picker("Theme override", selection: $override) {
                Text("None (use config)").tag(String?.none)
                ForEach(themeNames, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .onChange(of: override) { _, name in runtime.setDebugThemeOverride(name) }
            .plumeID(AccessibilityID.debugThemeOverridePicker, value: override ?? "none", setValue: { override = $0 == "none" ? nil : $0 })
        } header: {
            Text("Theme (Debug)")
        } footer: {
            Text(themeNames.isEmpty
                ? "Install Ghostty.app to list its themes."
                : "Recolors the app and its terminals. The Ghostty config is never changed.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
