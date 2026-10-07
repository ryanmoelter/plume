import SwiftUI

/// The side presentation of the info pane: one glass box at the chat's
/// top-trailing corner that is either a row of icons or the full pane, and
/// grows between the two in place.
///
/// Open means pinned beside the chat, hovered, or opened on demand in a
/// window too narrow to pin it. Only pinning persists; the other two close on
/// their own.
struct InfoSidePane: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts
    let glass: Glass
    let geometry: InfoPaneLayout.SideGeometry
    /// How much of the bottom edge the composer covers. The open pane and its
    /// dismiss target stop clear of it, so a click there still reaches the
    /// composer.
    let bottomInset: CGFloat
    let onCollapsedHeight: (CGFloat) -> Void
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void
    let onOpenSideChat: () -> Void

    @State private var settings = AppSettings.shared
    @State private var isHovering = false
    @State private var isHoverOpen = false
    @State private var isFloatingOpen = false
    @State private var showsCompletedSubagents = false
    @State private var pendingHover: Task<Void, Never>?
    @State private var collapsedSize: CGSize = .zero
    @State private var expandedHeight: CGFloat = 0
    @State private var availableHeight: CGFloat = 0

    /// Long enough that a click aimed at the collapsed row lands on it rather
    /// than on the header the open pane puts under the pointer.
    private static var hoverOpenDelay: Duration { .milliseconds(300) }
    private static var hoverCloseDelay: Duration { .milliseconds(250) }

    private var isOpen: Bool { geometry.isPinned || isHoverOpen || isFloatingOpen }

    private var maxExpandedHeight: CGFloat {
        max(0, availableHeight - dimensions.panelInset)
    }

    /// The only thing that animates between the two forms. Both keep their
    /// own size inside it, so opening never relays out the pane's text.
    private var boxSize: CGSize {
        isOpen
            ? CGSize(width: InfoPaneLayout.paneWidth, height: min(expandedHeight, maxExpandedHeight))
            : collapsedSize
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isFloatingOpen {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { closeTransient() }
                    .plumeID(AccessibilityID.infoPaneFloatingDismiss, invoke: closeTransient)
            }
            box
                .padding(.top, dimensions.panelInset)
                .padding(.trailing, geometry.trailingInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .padding(.bottom, bottomInset + dimensions.panelInset)
        .animation(.snappy(duration: 0.22), value: isOpen)
        // Hover never reports an exit for a view that changes under the
        // pointer, so a pin or a resize clears it by hand.
        .onChange(of: settings.infoPaneState) { closeTransient() }
        .onChange(of: geometry.fitsBeside) { closeTransient() }
        .onDisappear { closeTransient() }
    }

    private var box: some View {
        // Both forms stay mounted and cross-fade, so the glass and the hover
        // region belong to one view and only its frame moves.
        ZStack(alignment: .topLeading) {
            collapsed
                .opacity(isOpen ? 0 : 1)
                .allowsHitTesting(!isOpen)
                .plumeControlsHidden(isOpen)
            expanded
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
                .plumeControlsHidden(!isOpen)
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: dimensions.panelCornerRadius))
        .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .plumeHover { hovering in
            isHovering = hovering
            updateHoverOpen()
        }
        .plumeID(AccessibilityID.infoPane, value: geometry.isPinned ? "pinned" : isOpen ? "open" : "collapsed")
    }

    private var collapsed: some View {
        Button(action: toggle) {
            InfoPaneCollapsedIcons(facts: facts)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(geometry.fitsBeside ? "Keep the info pane open" : "Open the info pane")
        .plumeID(AccessibilityID.infoPanePill)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { old, size in
            resize(isFirst: old == .zero) { collapsedSize = size }
            onCollapsedHeight(size.height)
        }
    }

    /// Scrolls once it outgrows the room above the composer, and hugs its
    /// content otherwise.
    private var expanded: some View {
        let content = InfoPaneContent(
            facts: facts,
            headerButton: headerButton,
            onOpenSubagent: { subagent in
                closeTransient()
                onOpenSubagent(subagent)
            },
            onOpenPlan: {
                closeTransient()
                onOpenPlan()
            },
            onOpenSideChat: {
                closeTransient()
                onOpenSideChat()
            },
            showsCompleted: $showsCompletedSubagents
        )
        .padding(12)
        .frame(width: InfoPaneLayout.paneWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, height in
            resize(isFirst: old == 0) { expandedHeight = height }
        }

        return ScrollView { content }
            .scrollDisabled(expandedHeight <= maxExpandedHeight)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: InfoPaneLayout.paneWidth, height: min(expandedHeight, maxExpandedHeight))
    }

    /// Grows the glass with its content, except on the first measurement, so
    /// a pane that starts open doesn't animate in.
    private func resize(isFirst: Bool, _ apply: () -> Void) {
        if isFirst {
            apply()
        } else {
            withAnimation(InfoPaneLayout.sectionAnimation, apply)
        }
    }

    private var headerButton: InfoPaneHeaderButton {
        if geometry.isPinned {
            InfoPaneHeaderButton(systemImage: "pin.fill", help: "Collapse the info pane", value: "pinned") {
                settings.infoPaneState = .collapsed
            }
        } else if geometry.fitsBeside {
            InfoPaneHeaderButton(systemImage: "pin", help: "Keep the info pane open", value: "transient") {
                settings.infoPaneState = .expanded
            }
        } else {
            InfoPaneHeaderButton(systemImage: "xmark", help: "Close the info pane", value: "floating") {
                closeTransient()
            }
        }
    }

    /// Pins and unpins where the pane fits beside the chat, and opens it over
    /// the chat on demand where it doesn't.
    private func toggle() {
        if geometry.fitsBeside {
            settings.infoPaneState = geometry.isPinned ? .collapsed : .expanded
        } else {
            let opens = !isOpen
            closeTransient()
            isFloatingOpen = opens
        }
    }

    /// Closes after a beat too, so a pointer grazing the edge of the growing
    /// box doesn't snap it shut.
    private func updateHoverOpen() {
        pendingHover?.cancel()
        let opens = isHovering
        guard opens != isHoverOpen else { return }
        pendingHover = Task {
            try? await Task.sleep(for: opens ? Self.hoverOpenDelay : Self.hoverCloseDelay)
            guard !Task.isCancelled else { return }
            isHoverOpen = opens
        }
    }

    private func closeTransient() {
        pendingHover?.cancel()
        isHovering = false
        isHoverOpen = false
        isFloatingOpen = false
    }
}
