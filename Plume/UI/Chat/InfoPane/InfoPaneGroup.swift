import SwiftUI

/// A section that shows one item as a row of its own, and two or more under a
/// collapsible `InfoPaneGroupHeader`.
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

/// The header of an `InfoPaneGroup`. With no count, it has nothing to
/// disclose, so it draws no chevron.
struct InfoPaneGroupHeader<Icon: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let title: String
    let count: Int?
    let isExpanded: Bool
    let accessibilityID: String
    var accessibilityValue: String?
    /// True while a control laid over the header is hovered.
    var suppressesWash = false
    /// Leaves room for a control laid over the trailing edge.
    var reservesTrailingControl = false
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { icon }
                Text(title)
                if let count {
                    Text("\(count)")
                        .emphasis(.subtle)
                    DisclosureChevron(isExpanded: isExpanded)
                }
                Spacer(minLength: 0)
                if reservesTrailingControl { OverlaidControlSpace() }
            }
            .emphasis(.secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: suppressesWash))
        .plumeID(accessibilityID, value: accessibilityValue ?? (isExpanded ? "expanded" : "collapsed"))
    }
}
