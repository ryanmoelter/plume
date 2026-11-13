#if DEBUG
import SwiftUI

/// The tools the CLI reported at `init`, for checking what an agent can reach.
/// The header's control value is the comma-joined list, for a driver.
struct AgentToolsSection: View {
    let names: [String]

    @State private var isExpanded = false

    var body: some View {
        InfoPaneBracketedSection(isExpanded: isExpanded) {
            InfoPaneSectionHeader(
                title: "Tools",
                icon: .symbol("wrench.and.screwdriver"),
                count: names.count,
                isExpanded: isExpanded,
                accessibilityID: AccessibilityID.infoPaneToolsToggle,
                accessibilityValue: names.joined(separator: ",")
            ) {
                withAnimation(InfoPaneLayout.sectionAnimation) { isExpanded.toggle() }
            }
        } rows: {
            if isExpanded {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: InfoPaneLayout.columnSpacing) {
                        InfoPaneIcon { Image(systemName: "wrench").hidden() }
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
                    .plumeID(AccessibilityID.infoPaneToolRow, label: name)
                }
            }
        }
    }
}
#endif
