import SwiftUI

/// The sidebar's spacing. Row heights and header gaps are measured from the
/// macOS 26 `List(.sidebar)`; the selection fill takes the footer buttons'
/// horizontal bounds, so a selected task and a hovered footer row line up.
enum SidebarMetrics {
    /// From the column edge to a row's selection fill.
    static let listHorizontalInset: CGFloat = SidebarFooterMetrics.inset
    /// From the selection fill to the row's content.
    static let rowHorizontalPadding: CGFloat = 12
    /// Above and below a row's content, inside its fill.
    static let rowVerticalPadding: CGFloat = 6
    static let selectionCornerRadius: CGFloat = 10
    /// A header sits 2 pt further out than a row's content, as the system's
    /// section headers do.
    static let headerLeadingPadding: CGFloat = 10
    static let headerMinHeight: CGFloat = 19
    /// Above every section header but the first.
    static let headerTopSpacing: CGFloat = 13
}

extension View {
    /// Lays this view out as a selectable sidebar row, with the selection
    /// fill behind it.
    func sidebarRow(isSelected: Bool) -> some View {
        padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
            .padding(.vertical, SidebarMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarSelectionFill(isSelected: isSelected))
            .contentShape(.rect)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Styles this view as a sidebar section header: 11 pt semibold in the
    /// secondary text style.
    func sidebarSectionHeader() -> some View {
        font(.subheadline.weight(.semibold))
            .emphasis(.secondary)
            .padding(.leading, SidebarMetrics.headerLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.headerMinHeight, alignment: .leading)
            .contentShape(.rect)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Gives every icon the same column, so labels line up whatever the symbol's
/// natural width.
struct SidebarIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .frame(width: 20)
            configuration.title
        }
    }
}
