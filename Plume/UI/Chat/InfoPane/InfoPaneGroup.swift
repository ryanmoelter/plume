import SwiftUI

/// A section that shows one item as a row of its own, and two or more as an
/// `InfoPaneBracketedSection`.
struct InfoPaneGroup<Single: View, Grouped: View>: View {
    let isGrouped: Bool
    /// Folding a lone row under a collapsed header would read as the row
    /// vanishing, so a group that just formed opens.
    let expand: () -> Void
    @ViewBuilder let single: Single
    @ViewBuilder let grouped: Grouped

    var body: some View {
        Group {
            if isGrouped { grouped } else { single }
        }
        .animation(InfoPaneLayout.sectionAnimation, value: isGrouped)
        .onChange(of: isGrouped) { _, isGrouped in
            if isGrouped { expand() }
        }
    }
}
