import SwiftUI

struct VisualsSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            ThemeSettingsSection()

            Section {
                LabeledContent {
                    HStack {
                        Slider(
                            value: $settings.chatFontSize,
                            in: AppSettings.chatFontSizeRange,
                            step: 1
                        )
                        Text("\(Int(settings.chatFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Text size")
                }

                LabeledContent {
                    HStack {
                        Slider(
                            value: $settings.codeFontSizeMultiplier,
                            in: AppSettings.codeFontSizeMultiplierRange,
                            step: 0.05
                        )
                        Text("\(Int(settings.codeFontSizeMultiplier * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Code size")
                    Text("Relative to text size")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Chat")
            }

            Section {
                Picker("Task marker", selection: $settings.sidebarTaskMarker) {
                    ForEach(SidebarTaskMarker.allCases) { marker in
                        Text(marker.title).tag(marker)
                    }
                }
                .pickerStyle(.segmented)
                .plumeID(
                    AccessibilityID.settingsSidebarTaskMarkerPicker,
                    value: settings.sidebarTaskMarker.rawValue,
                    setValue: { raw in
                        if let marker = SidebarTaskMarker(rawValue: raw) { settings.sidebarTaskMarker = marker }
                    }
                )
                Toggle(isOn: $settings.sidebarColorsTaskNames) {
                    Text("Color task names")
                    Text("Draws a colored task's name in its color")
                        .foregroundStyle(.secondary)
                }
                .plumeID(
                    AccessibilityID.settingsSidebarColorsTaskNamesToggle,
                    value: settings.sidebarColorsTaskNames ? "on" : "off",
                    invoke: { settings.sidebarColorsTaskNames.toggle() }
                )
                Toggle("Bold task names", isOn: $settings.sidebarBoldTaskNames)
                    .plumeID(
                        AccessibilityID.settingsSidebarBoldTaskNamesToggle,
                        value: settings.sidebarBoldTaskNames ? "on" : "off",
                        invoke: { settings.sidebarBoldTaskNames.toggle() }
                    )
            } header: {
                Text("Sidebar")
            }

            Section {
                Toggle("Animate chat message motion", isOn: $settings.animateChatMotion)
                Toggle("Fade streamed text in as it arrives", isOn: $settings.animateCharacterReveal)
            } header: {
                Text("Animation")
            }
        }
        .formStyle(.grouped)
    }
}
