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

                Button("Reset All") { settings.shortcutBindings.resetAll() }
                    .plumeID(AccessibilityID.shortcutResetAllButton)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new keys. If another command in this list has the same keys, that command becomes unassigned. A shortcut with Command or Option works even when a terminal has focus, so the terminal no longer receives it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
