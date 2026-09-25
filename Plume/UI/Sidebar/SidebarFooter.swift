import SwiftUI
import AppKit

/// Pinned to the bottom of the sidebar, below the task list rather than
/// after its last row — it stays put whether the list is empty or
/// overflowing. The quota reading sits at the top (below a build label in
/// DEBUG), then the actions.
struct SidebarFooter: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var archiveShown: Bool
    private var installedProviders: Set<AgentProviderKind> {
        AgentCLIInstallation.displayedProviders(AgentCLIAvailability.shared.providers ?? [])
    }
    @State private var cliRefresh = 0
    @State private var keepAwakeShown = false
    @State private var coordinator = KeepAwakeCoordinator.shared
    @State private var settings = AppSettings.shared
    @State private var updates = UpdateController.shared

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.chatSurface(.divider, colorScheme: colorScheme))
                .frame(height: 1)

            VStack(spacing: 0) {
#if DEBUG
                SidebarBuildLabel()
#endif
                if let availableUpdate = updates.availableUpdate {
                    Button {
                        updates.showAvailableUpdate()
                    } label: {
                        SidebarFooterRow(
                            icon: "arrow.down.circle",
                            title: "Update Available",
                            iconTint: ChatRole.attention(for: colorScheme),
                            detail: availableUpdate.displayVersion
                        )
                    }
                    .help("Plume \(availableUpdate.displayVersion) is available")
                    .plumeID(AccessibilityID.sidebarUpdateButton)
                    .buttonStyle(SidebarFooterButtonStyle())
                }

                if installedProviders.contains(.claudeCode) { SidebarQuotaRow() }
                if installedProviders.contains(.codex) { SidebarCodexQuotaRow() }

                Button {
                    keepAwakeShown = true
                } label: {
                    SidebarFooterRow(
                        icon: keepAwakeIcon,
                        title: keepAwakeTitle,
                        subtitle: keepAwakeSubtitle,
                        iconTint: keepAwakeTint,
                        hasMoreOptions: true,
                        detail: keepAwakeDetail,
                        detailSymbol: keepAwakeDetailSymbol,
                        detailSymbolTint: keepAwakeDetailSymbolTint
                    )
                }
                .help(keepAwakeHelp)
                .plumeID(AccessibilityID.sidebarKeepAwakeButton)
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
                .plumeID(AccessibilityID.sidebarArchiveButton)
                .buttonStyle(SidebarFooterButtonStyle())

                SettingsLink {
                    SidebarFooterRow(icon: "gearshape", title: "Settings")
                }
                .plumeID(AccessibilityID.sidebarSettingsButton)
                .buttonStyle(SidebarFooterButtonStyle(bottomCornerRadius: bottomCornerRadius))
            }
            .padding(.vertical, SidebarFooterMetrics.inset)
        }
        .task(id: cliRefresh) {
            await AgentCLIAvailability.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cliRefresh += 1
        }
    }

    private var isBatteryBlocked: Bool {
        switch coordinator.offReason {
        case .battery, .batteryLow: true
        case .refused, nil: false
        }
    }

    /// An empty cup is not caffeinated; a steaming one is.
    private var keepAwakeIcon: String {
        coordinator.isHolding ? "cup.and.heat.waves.fill" : "cup.and.saucer"
    }

    /// Tinted only while held. Warning rather than attention: the Mac staying
    /// up is a condition worth knowing about, not the agent wanting the user.
    /// Danger once the lid override is engaged, since a shut Mac in a bag is
    /// a step past "worth knowing about".
    private var keepAwakeTint: Color? {
        guard coordinator.isHolding else { return nil }
        return isLidOverrideEngaged ? ChatRole.danger(for: colorScheme) : ChatRole.warning(for: colorScheme)
    }

    private var isLidOverrideEngaged: Bool {
        coordinator.isHolding && coordinator.lidOverrideStatus == .engaged
    }

    private var keepAwakeSubtitle: String? {
        isLidOverrideEngaged ? "even if the lid is closed" : nil
    }

    /// The present participle says it is happening now, rather than naming
    /// the setting.
    private var keepAwakeTitle: String {
        coordinator.isHolding ? "Keeping Awake" : "Keep Awake"
    }

    /// What is holding the Mac awake, or the mode when nothing is. Auto with
    /// no reasons needs no label: the title already says what it does. The
    /// remote-control glyph rides alongside, so it is never named in words.
    /// Battery blocking is glyph-only too, via `keepAwakeDetailSymbol`.
    private var keepAwakeDetail: String? {
        if isBatteryBlocked { return nil }
        let tally = coordinator.tally
        if tally.working > 0 { return "\(tally.working) working" }
        if tally.backgroundTasks > 0 { return "\(tally.backgroundTasks) in background" }
        if tally.remotelyControlled { return nil }
        return settings.keepAwakeMode == .auto ? nil : settings.keepAwakeMode.label
    }

    /// The reason keep-awake is off or on, as a glyph rather than words.
    /// Battery blocking takes priority over remote control, the same way it
    /// takes priority over the working count in `keepAwakeDetail`.
    private var keepAwakeDetailSymbol: String? {
        if isBatteryBlocked { return Self.batteryGlyph(percent: coordinator.powerSnapshot.percent) }
        return coordinator.tally.remotelyControlled ? StatusSymbol.remoteControl.name : nil
    }

    /// Only shown while battery-blocked, since charging always skips the
    /// cutoff and the glyph never appears while charging.
    private var keepAwakeDetailSymbolTint: Color? {
        switch coordinator.offReason {
        case .batteryLow: ChatRole.danger(for: colorScheme)
        case .battery, .refused, nil: nil
        }
    }

    /// Buckets a live reading to the nearest SF Symbol glyph. A nil reading
    /// (percent unknown) keeps the look `.battery` blocking already had.
    static func batteryGlyph(percent: Int?) -> String {
        guard let percent else { return "battery.25percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var keepAwakeHelp: String {
        switch coordinator.offReason {
        case .battery: return "Your Mac can sleep while on battery"
        case .batteryLow(let percent): return "Your Mac can sleep while below \(percent)% battery"
        case .refused, nil: break
        }
        if isLidOverrideEngaged { return "Keeping your Mac awake, even with the lid closed" }
        return coordinator.isHolding ? "Keeping your Mac awake" : "Your Mac can sleep"
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
    /// A dim second line under the title, for state the title alone would
    /// understate.
    var subtitle: String?
    /// Set only when the row carries state of its own, which the footer's
    /// plain rows do not. Tints the title too, not just the icon.
    var iconTint: Color?
    /// Draws a trailing chevron, for a row that opens a popover rather than
    /// performing its action outright.
    var hasMoreOptions = false
    /// A few words of state, shown before the chevron.
    var detail: String?
    /// A system symbol appended after `detail`, e.g. remote-control or
    /// battery-blocked.
    var detailSymbol: String?
    /// Tint for `detailSymbol` alone, e.g. red for a low-battery cutoff.
    var detailSymbolTint: Color?

    var body: some View {
        // Stacks only when the title and its detail cannot share a line,
        // rather than at a guessed sidebar width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                glyph
                titleBlock
                Spacer(minLength: 4)
                detailLabel
                chevron
            }
            HStack(spacing: 8) {
                glyph
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
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
        .animation(.default, value: subtitle)
        .animation(.default, value: detail)
        .animation(.default, value: detailSymbol)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let subtitle {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).contentTransition(.numericText())
                Text(subtitle)
                    .font(.caption)
                    .emphasis(.secondary)
            }
        } else {
            Text(title).contentTransition(.numericText())
        }
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
        if detail != nil || detailSymbol != nil {
            HStack(spacing: 3) {
                if let detail {
                    Text(detail)
                        .contentTransition(.numericText())
                        .emphasis(.secondary)
                }
                if let detailSymbol {
                    if let detailSymbolTint {
                        Image(systemName: detailSymbol)
                            .imageScale(.small)
                            .foregroundStyle(detailSymbolTint)
                    } else {
                        // Full emphasis: it is a state, not a caption on one.
                        Image(systemName: detailSymbol)
                            .imageScale(.small)
                            .emphasis(.primary)
                    }
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
                .plumeHover { isHovered = $0 }
        }
    }
}
