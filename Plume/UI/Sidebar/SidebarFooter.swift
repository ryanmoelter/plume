import SwiftUI
#if DEBUG
import SwiftData
#endif

/// Pinned to the bottom of the sidebar, below the task list rather than
/// after its last row — it stays put whether the list is empty or
/// overflowing. Archive above, Settings below.
struct SidebarFooter: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var archiveShown: Bool
    @State private var keepAwakeShown = false
    @State private var coordinator = KeepAwakeCoordinator.shared
    @State private var settings = AppSettings.shared

#if DEBUG
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskGroup.orderIndex) private var groups: [TaskGroup]
    @State private var outlines = ChatItemOutlines.shared
#endif

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.chatSurface(.divider, colorScheme: colorScheme))
                .frame(height: 1)

            VStack(spacing: 0) {
#if DEBUG
                Button {
                    outlines.isEnabled.toggle()
                } label: {
                    SidebarFooterRow(
                        icon: outlines.isEnabled ? "square.dashed.inset.filled" : "square.dashed",
                        title: "Chat Item Boxes"
                    )
                }
                .help("Outline every lazy item in the chat, labelled with its kind and height")
                .buttonStyle(SidebarFooterButtonStyle())

                Button {
                    SidebarFixtures.seed(in: context, existingGroups: groups)
                } label: {
                    SidebarFooterRow(icon: "ladybug", title: "Seed Fixtures")
                }
                .help("Seed a \"\(SidebarFixtures.groupName)\" group covering every sidebar state")
                .buttonStyle(SidebarFooterButtonStyle())
#endif

                Button {
                    keepAwakeShown = true
                } label: {
                    SidebarFooterRow(icon: keepAwakeIcon, title: "Keep Awake", isIconProminent: coordinator.isHolding)
                }
                .help(keepAwakeHelp)
                .accessibilityIdentifier(AccessibilityID.sidebarKeepAwakeButton)
                .buttonStyle(SidebarFooterButtonStyle())
                .popover(isPresented: $keepAwakeShown, arrowEdge: .trailing) {
                    KeepAwakePanel()
                }

                Button {
                    archiveShown = true
                } label: {
                    SidebarFooterRow(icon: "archivebox", title: "Archive")
                }
                .help("Show archived tasks")
                .accessibilityIdentifier(AccessibilityID.sidebarArchiveButton)
                .buttonStyle(SidebarFooterButtonStyle())

                SettingsLink {
                    SidebarFooterRow(icon: "gearshape", title: "Settings")
                }
                .accessibilityIdentifier(AccessibilityID.sidebarSettingsButton)
                .buttonStyle(SidebarFooterButtonStyle(bottomCornerRadius: bottomCornerRadius))
            }
            .padding(.vertical, SidebarFooterMetrics.inset)
        }
    }

    /// Slashed when the feature is off, so "off" never reads the same as
    /// "on with nothing to hold".
    private var keepAwakeIcon: String {
        if settings.keepAwakeMode == .never { return "cup.and.saucer" }
        return coordinator.isHolding ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    private var keepAwakeHelp: String {
        coordinator.isHolding ? "Holding the Mac awake" : "The Mac can sleep"
    }

    /// The last row's wash sits inside the window's corner, so it curves
    /// concentrically with it rather than repeating its radius.
    private var bottomCornerRadius: CGFloat {
        ComposerPanelMetrics.concentricRadius(
            outer: dimensions.windowCornerRadius,
            inset: SidebarFooterMetrics.inset
        )
    }
}

enum SidebarFooterMetrics {
    static let inset: CGFloat = 4
    static let washCornerRadius: CGFloat = 4
}

private struct SidebarFooterRow: View {
    let icon: String
    let title: String
    /// Dims the icon alone, rather than the whole row, which would read as
    /// disabled.
    var isIconProminent = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .emphasis(isIconProminent ? .primary : .secondary)
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
    /// Set only on the bottom-most row, which meets the window's corner.
    var bottomCornerRadius: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterButtonBody(configuration: configuration, bottomCornerRadius: bottomCornerRadius)
    }

    private struct SidebarFooterButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        @State private var isHovered = false
        let configuration: ButtonStyleConfiguration
        let bottomCornerRadius: CGFloat?

        var body: some View {
            let bottom = bottomCornerRadius ?? SidebarFooterMetrics.washCornerRadius
            configuration.label
                .background(
                    Color.chatSurface(.divider, colorScheme: colorScheme)
                        .opacity(isHovered || configuration.isPressed ? 1 : 0)
                )
                .clipShape(
                    .rect(
                        topLeadingRadius: SidebarFooterMetrics.washCornerRadius,
                        bottomLeadingRadius: bottom,
                        bottomTrailingRadius: bottom,
                        topTrailingRadius: SidebarFooterMetrics.washCornerRadius
                    )
                )
                .padding(.horizontal, SidebarFooterMetrics.inset)
                .onHover { isHovered = $0 }
        }
    }
}
