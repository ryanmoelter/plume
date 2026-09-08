import SwiftUI

/// Pinned to the bottom of the sidebar, below the task list rather than
/// after its last row — it stays put whether the list is empty or
/// overflowing. Archive above, Settings below.
struct SidebarFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var archiveShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.chatSurface(.divider, colorScheme: colorScheme))
                .frame(height: 1)

            VStack(spacing: 0) {
                Button {
                    archiveShown = true
                } label: {
                    SidebarFooterRow(icon: "archivebox", title: "Archive")
                }
                .help("Show archived tasks")
                .accessibilityIdentifier(AccessibilityID.sidebarArchiveButton)

                SettingsLink {
                    SidebarFooterRow(icon: "gearshape", title: "Settings")
                }
                .accessibilityIdentifier(AccessibilityID.sidebarSettingsButton)
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .padding(.vertical, 4)
        }
    }
}

private struct SidebarFooterRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(.rect)
    }
}

/// A hover wash in place of the platform's default button chrome, matching
/// `SidebarSelectionFill`'s language for "this row is live" rather than
/// introducing a new one.
private struct SidebarFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterButtonBody(configuration: configuration)
    }

    private struct SidebarFooterButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        @State private var isHovered = false
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .background(
                    Color.chatSurface(.divider, colorScheme: colorScheme)
                        .opacity(isHovered || configuration.isPressed ? 1 : 0)
                )
                .clipShape(.rect(cornerRadius: 4))
                .padding(.horizontal, 4)
                .onHover { isHovered = $0 }
        }
    }
}
