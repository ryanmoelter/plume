import SwiftUI

/// Hosts the side presentation of the info pane around a chat tab's content,
/// and owns the toolbar button that shows and hides it.
///
/// With room beside the chat, the pane takes a column of its own in the state
/// the user left it: expanded, collapsed to icons, or hidden. Without room it
/// floats over the chat only on demand, so a narrow window never loses prose
/// to it.
struct InfoPaneHost<Content: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts
    let glass: Glass
    /// How much of the bottom edge the composer covers. The floating pane and
    /// its dismiss target stop clear of it, so a click there still reaches the
    /// composer.
    let bottomInset: CGFloat
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void
    @ViewBuilder let content: Content

    @State private var settings = AppSettings.shared
    @State private var size: CGSize = .zero
    @State private var isFloatingOpen = false
    @State private var isHoveringColumn = false
    @State private var isHoveringPane = false
    @State private var isHoverExpanded = false
    @State private var pendingHoverCollapse: Task<Void, Never>?

    private static var hoverCollapseDelay: Duration { .milliseconds(250) }

    private var isSide: Bool { settings.infoPanePresentation == .side }

    private var fitsBeside: Bool {
        InfoPaneLayout.fitsBeside(
            width: size.width,
            contentWidth: dimensions.contentWidth,
            inset: dimensions.panelInset * 2
        )
    }

    private var isShown: Bool {
        fitsBeside ? settings.infoPaneState != .hidden : isFloatingOpen
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isSide, fitsBeside {
                besidePane
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .overlay(alignment: .topTrailing) {
            if isSide, !fitsBeside, isFloatingOpen {
                floatingPane
            }
        }
        .animation(.snappy(duration: 0.2), value: settings.infoPaneState)
        .animation(.snappy(duration: 0.2), value: isFloatingOpen)
        .animation(.snappy(duration: 0.15), value: isHoverExpanded)
        .onChange(of: fitsBeside) { isFloatingOpen = false }
        // Hover never reports an exit for a view that goes away under the
        // pointer, so leaving the collapsed form must clear it by hand.
        .onChange(of: settings.infoPaneState) { resetHover() }
        .onChange(of: settings.infoPanePresentation) { resetHover() }
        .onDisappear { resetHover() }
        .toolbar {
            if isSide {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggle) {
                        Label("Info Pane", systemImage: "sidebar.trailing")
                    }
                    .help(isShown ? "Hide the info pane" : "Show the info pane")
                    .plumeID(AccessibilityID.infoPaneToggle, value: isShown ? "shown" : "hidden", invoke: toggle)
                }
            }
        }
    }

    private func toggle() {
        if fitsBeside {
            settings.infoPaneState = settings.infoPaneState == .hidden ? .expanded : .hidden
        } else {
            isFloatingOpen.toggle()
        }
    }

    @ViewBuilder
    private var besidePane: some View {
        switch settings.infoPaneState {
        case .expanded:
            pane(collapseToggle: .init(isCollapsed: false) { settings.infoPaneState = .collapsed })
                .padding([.top, .trailing], dimensions.panelInset)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .collapsed:
            collapsedColumn
                .padding([.top, .trailing], dimensions.panelInset)
                .transition(.opacity)
        case .hidden:
            EmptyView()
        }
    }

    /// The icon column, with the full pane laid over the chat while either is
    /// hovered. Overlaid rather than placed, so hovering never reflows the
    /// conversation.
    private var collapsedColumn: some View {
        InfoPaneIconColumn(facts: facts)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
            .contentShape(.rect)
            .plumeHover { hovering in
                isHoveringColumn = hovering
                updateHoverExpansion()
            }
            .plumeID(AccessibilityID.infoPaneIconColumn)
            .overlay(alignment: .topTrailing) {
                if isHoverExpanded {
                    pane(collapseToggle: .init(isCollapsed: true) { settings.infoPaneState = .expanded })
                        .plumeHover { hovering in
                            isHoveringPane = hovering
                            updateHoverExpansion()
                        }
                        // An overlay is offered only the column's height, so
                        // the pane is given the room below the window's top
                        // instead, stopping clear of the composer.
                        .frame(height: hoverPaneHeight, alignment: .top)
                        .transition(.opacity)
                }
            }
    }

    /// Opens at once and closes after a beat, so crossing the gap between the
    /// column and the pane it opened doesn't close it.
    private func updateHoverExpansion() {
        pendingHoverCollapse?.cancel()
        if isHoveringColumn || isHoveringPane {
            isHoverExpanded = true
            return
        }
        pendingHoverCollapse = Task {
            try? await Task.sleep(for: Self.hoverCollapseDelay)
            guard !Task.isCancelled else { return }
            isHoverExpanded = false
        }
    }

    private func resetHover() {
        pendingHoverCollapse?.cancel()
        isHoveringColumn = false
        isHoveringPane = false
        isHoverExpanded = false
    }

    private var floatingPane: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { isFloatingOpen = false }
                .plumeID(AccessibilityID.infoPaneFloatingDismiss, invoke: { isFloatingOpen = false })
            pane(collapseToggle: nil)
                .padding([.top, .trailing], dimensions.panelInset)
        }
        .padding(.bottom, bottomInset)
        .transition(.opacity)
    }

    private var hoverPaneHeight: CGFloat {
        max(0, size.height - bottomInset - dimensions.panelInset * 2)
    }

    /// Scrolls once it outgrows the height it is offered, and hugs its
    /// content otherwise.
    private func pane(collapseToggle: InfoPaneContent.CollapseToggle?) -> some View {
        let inner = InfoPaneContent(
            facts: facts,
            style: .side,
            onOpenSubagent: onOpenSubagent,
            onOpenPlan: onOpenPlan,
            collapseToggle: collapseToggle
        )
        .padding(12)
        .frame(width: InfoPaneLayout.paneWidth, alignment: .leading)

        return ViewThatFits(in: .vertical) {
            inner
            ScrollView { inner }
        }
        .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
    }
}
