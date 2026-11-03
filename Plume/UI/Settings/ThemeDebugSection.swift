#if DEBUG
import SwiftUI

/// Swaps the theme Plume's own colors come from, without touching the
/// terminals.
struct ThemeDebugSection: View {
    private let runtime = GhosttyRuntime.shared
    @State private var themeNames = GhosttyRuntime.debugThemeNames()
    @State private var override = GhosttyRuntime.shared.debugThemeOverrideName

    var body: some View {
        Section {
            Picker("Chrome theme", selection: $override) {
                Text("None (use config)").tag(String?.none)
                ForEach(themeNames, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .onChange(of: override) { _, name in runtime.setDebugThemeOverride(name) }
            .plumeID(AccessibilityID.debugThemeOverridePicker, value: override ?? "none")
        } header: {
            Text("Theme (Debug)")
        } footer: {
            Text(themeNames.isEmpty
                ? "Install Ghostty.app to list its themes."
                : "Recolors chrome, tints, the extended palette, Linear and Home. Terminals keep the config's theme.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
