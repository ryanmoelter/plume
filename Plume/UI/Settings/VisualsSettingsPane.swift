import SwiftUI

struct VisualsSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            ThemeSettingsSection()

            Section {
                SidebarTaskPreview()
                Toggle("Show task color bar", isOn: $settings.sidebarShowsTaskColorBar)
                    .plumeID(
                        AccessibilityID.settingsSidebarShowsTaskColorBarToggle,
                        value: settings.sidebarShowsTaskColorBar ? "on" : "off",
                        invoke: { settings.sidebarShowsTaskColorBar.toggle() }
                    )
                Toggle("Color task names", isOn: $settings.sidebarColorsTaskNames)
                .plumeID(
                    AccessibilityID.settingsSidebarColorsTaskNamesToggle,
                    value: settings.sidebarColorsTaskNames ? "on" : "off",
                    invoke: { settings.sidebarColorsTaskNames.toggle() }
                )
                Toggle("Color task icons", isOn: $settings.sidebarColorsTaskIcons)
                    .plumeID(
                        AccessibilityID.settingsSidebarColorsTaskIconsToggle,
                        value: settings.sidebarColorsTaskIcons ? "on" : "off",
                        invoke: { settings.sidebarColorsTaskIcons.toggle() }
                    )
                Toggle("Suggest filled icons", isOn: $settings.sidebarSuggestsFilledIcons)
                    .plumeID(
                        AccessibilityID.settingsSidebarSuggestsFilledIconsToggle,
                        value: settings.sidebarSuggestsFilledIcons ? "on" : "off",
                        invoke: { settings.sidebarSuggestsFilledIcons.toggle() }
                    )
                Toggle("Use two-tone icons", isOn: $settings.sidebarTwoToneIcons)
                    .plumeID(
                        AccessibilityID.settingsSidebarTwoToneIconsToggle,
                        value: settings.sidebarTwoToneIcons ? "on" : "off",
                        invoke: { settings.sidebarTwoToneIcons.toggle() }
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
                Toggle("Animate chat message motion", isOn: $settings.animateChatMotion)
                Toggle("Fade streamed text in as it arrives", isOn: $settings.animateCharacterReveal)
            } header: {
                Text("Animation")
            }
        }
        .formStyle(.grouped)
    }
}
