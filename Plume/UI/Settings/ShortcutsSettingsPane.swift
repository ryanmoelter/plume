import SwiftUI

struct ShortcutsSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.label) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(shortcut: settings.shortcutBindings[action]) { shortcut in
                                settings.shortcutBindings.assign(shortcut, to: action)
                            }
                            .frame(width: 120, height: 22)
                            .plumeID(
                                AccessibilityID.shortcutRecorder,
                                label: action.label,
                                value: settings.shortcutBindings[action]?.displayName ?? "Unassigned",
                                setValue: { chord in
                                    guard let shortcut = MenuShortcut(displayName: chord) else { return }
                                    settings.shortcutBindings.assign(shortcut, to: action)
                                }
                            )

                            Button {
                                settings.shortcutBindings.reset(action)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!settings.shortcutBindings.isCustomized(action))
                            .plumeID(AccessibilityID.shortcutResetButton, label: action.label)
                        }
                    }
                }

                Button("Reset all") { settings.shortcutBindings.resetAll() }
                    .plumeID(AccessibilityID.shortcutResetAllButton)
            } header: {
                Text("Keyboard shortcuts")
            }
        }
        .formStyle(.grouped)
    }
}
