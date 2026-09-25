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

                Picker(selection: $settings.composerSendKey) {
                    Text("⌘Return").tag(ComposerSendKey.commandReturn)
                    Text("Return").tag(ComposerSendKey.returnKey)
                } label: {
                    Text("Send message with")
                    Text("⇧Return always enters a new line")
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
