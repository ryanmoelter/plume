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
                    SidebarFooterRow(
                        icon: keepAwakeIcon,
                        title: keepAwakeTitle,
                        iconTint: keepAwakeTint,
                        hasMoreOptions: true,
                        detail: keepAwakeDetail,
                        showsRemoteControl: isBatteryBlocked ? false : coordinator.tally.remotelyControlled
                    )
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

    private var isBatteryBlocked: Bool {
        coordinator.offReason == .battery
    }

    /// An empty cup is not caffeinated; a steaming one is. Battery blocking
    /// gets its own glyph, since neither cup explains why it's not held.
    private var keepAwakeIcon: String {
        if isBatteryBlocked { return "battery.25percent" }
        return coordinator.isHolding ? "cup.and.heat.waves.fill" : "cup.and.saucer"
    }

    /// Tinted only while held. Warning rather than attention: the Mac staying
    /// up is a condition worth knowing about, not the agent wanting the user.
    private var keepAwakeTint: Color? {
        coordinator.isHolding ? ChatRole.warning(for: colorScheme) : nil
    }

    /// The present participle says it is happening now, rather than naming
    /// the setting.
    private var keepAwakeTitle: String {
        coordinator.isHolding ? "Keeping Awake" : "Keep Awake"
    }

    /// What is holding the Mac awake, or the mode when nothing is. Auto with
    /// no reasons needs no label: the title already says what it does. The
    /// remote-control glyph rides alongside, so it is never named in words.
    private var keepAwakeDetail: String? {
        if isBatteryBlocked { return "On battery" }
        let tally = coordinator.tally
        if tally.working > 0 { return "\(tally.working) working" }
        if tally.remotelyControlled { return nil }
        return settings.keepAwakeMode == .auto ? nil : settings.keepAwakeMode.label
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
    /// Set only when the row carries state of its own, which the footer's
    /// plain rows do not. Tints the title too, not just the icon.
    var iconTint: Color?
    /// Draws a trailing chevron, for a row that opens a popover rather than
    /// performing its action outright.
    var hasMoreOptions = false
    /// A few words of state, shown before the chevron.
    var detail: String?
    /// Appends the remote-control glyph after `detail`.
    var showsRemoteControl = false

    var body: some View {
        // Stacks only when the title and its detail cannot share a line,
        // rather than at a guessed sidebar width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                glyph
                Text(title).contentTransition(.numericText())
                Spacer(minLength: 4)
                detailLabel
                chevron
            }
            HStack(spacing: 8) {
                glyph
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).contentTransition(.numericText())
                    detailLabel
                }
                Spacer(minLength: 0)
                chevron
            }
        }
        .lineLimit(1)
        // Untinted rows keep the inherited style rather than being forced to
        // `.primary`, so they render as the unstated default did.
        .foregroundStyle(tintOrInherited)
        .animation(.default, value: icon)
        .animation(.default, value: title)
        .animation(.default, value: detail)
        .animation(.default, value: showsRemoteControl)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(.rect)
    }

    /// One `Image` across both states, not a branch per state: an if/else
    /// reads as two different views and never transitions.
    private var glyph: some View {
        Image(systemName: icon)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 16)
    }

    @ViewBuilder
    private var detailLabel: some View {
        if detail != nil || showsRemoteControl {
            HStack(spacing: 3) {
                if let detail {
                    Text(detail)
                        .contentTransition(.numericText())
                        .emphasis(.secondary)
                }
                if showsRemoteControl {
                    // Full emphasis: it is a state, not a caption on one.
                    Image(systemName: StatusSymbol.remoteControl.name)
                        .imageScale(.small)
                        .emphasis(.primary)
                }
            }
            .fixedSize()
        }
    }

    /// Full emphasis, not a hint: it is the only thing saying this row opens
    /// something rather than acting.
    @ViewBuilder
    private var chevron: some View {
        if hasMoreOptions {
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .emphasis(.primary)
        }
    }

    private var tintOrInherited: AnyShapeStyle {
        iconTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground)
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
