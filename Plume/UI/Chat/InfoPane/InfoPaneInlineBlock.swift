import SwiftUI

/// The inline presentation: the info pane as a block after the last message.
/// Drawn with a hairline rather than glass, because the composer's glass sits
/// over it most of the time.
struct InfoPaneInlineBlock: View, ThemedView {
    @Environment(\.theme) var theme

    let facts: InfoPaneFacts
    let onOpenSubagent: (SubagentTranscript) -> Void
    let onOpenPlan: () -> Void

    var body: some View {
        InfoPaneContent(
            facts: facts,
            style: .inline,
            onOpenSubagent: onOpenSubagent,
            onOpenPlan: onOpenPlan
        )
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        }
        .padding(.top, dimensions.messageSpacing)
        .padding(.bottom, dimensions.verticalPadding)
    }
}
