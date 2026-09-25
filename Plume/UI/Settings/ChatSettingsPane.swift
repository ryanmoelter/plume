import SwiftUI

struct ChatSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Text size")
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

                HStack {
                    Text("Code size")
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

                Picker("Send message with", selection: $settings.composerSendKey) {
                    Text("⌘Return").tag(ComposerSendKey.commandReturn)
                    Text("Return").tag(ComposerSendKey.returnKey)
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("Code size scales code relative to the text size. The other key inserts a new line.")
                    .foregroundStyle(.secondary)
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
