import SwiftUI

/// The inline presentation: the info pane as a block after the last message.
/// Drawn with a hairline rather than glass, because the composer's glass sits
/// over it most of the time. Collapses to the same row of icons the side pane
/// does, and shares its state.
struct InfoPaneInlineBlock: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void

    @State private var settings = AppSettings.shared
    @State private var showsCompletedSubagents = false

    var body: some View {
        Group {
            if settings.infoPaneState == .expanded {
                InfoPaneContent(
                    facts: facts,
                    headerButton: InfoPaneHeaderButton(
                        systemImage: "chevron.up",
                        help: "Collapse the info pane",
                        value: "expanded"
                    ) { settings.infoPaneState = .collapsed },
                    onOpenSubagent: onOpenSubagent,
                    onOpenPlan: onOpenPlan,
                    showsCompleted: $showsCompletedSubagents
                )
            } else {
                InfoPaneHeader(
                    button: InfoPaneHeaderButton(
                        systemImage: "chevron.down",
                        help: "Expand the info pane",
                        value: "collapsed"
                    ) { settings.infoPaneState = .expanded }
                ) {
                    InfoPaneCollapsedIcons(facts: facts)
                }
            }
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        }
        .plumeID(AccessibilityID.infoPane, value: settings.infoPaneState == .expanded ? "inline" : "inline-collapsed")
        .padding(.top, dimensions.messageSpacing)
        .padding(.bottom, dimensions.verticalPadding)
    }
}
