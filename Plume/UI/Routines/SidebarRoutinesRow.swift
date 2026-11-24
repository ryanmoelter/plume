import SwiftUI

/// The sidebar row under Home that opens the Routines page.
struct SidebarRoutinesRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        SidebarIconTitle(
            icon: Image(systemName: "clock.arrow.circlepath").imageScale(.large),
            iconMinWidth: SidebarMetrics.taskIconMinWidth,
            spacing: 5
        ) {
            Text("Routines")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Routines")
        .plumeID(AccessibilityID.sidebarRoutinesRow, value: isSelected ? "selected" : nil, invoke: onSelect)
    }
}
