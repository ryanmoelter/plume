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
    /// From the selection fill's edge to a task's color bar.
    static let tintBarInset: CGFloat = 3
    static let tintBarWidth: CGFloat = 3
    /// A header sits 2 pt further out than a row's content, as the system's
    /// section headers do.
    static let headerLeadingPadding: CGFloat = 10
    /// The weight `sidebarSectionHeader()` gives a header's text.
    static let headerWeight = Font.Weight.semibold
    static let headerMinHeight: CGFloat = 19
    /// Above every section header but the first.
    static let headerTopSpacing: CGFloat = 13
}

extension View {
    /// Lays this view out as a selectable sidebar row, with the selection
    /// fill behind it and, given a `tintBar` color, a bar at its leading edge.
    func sidebarRow(isSelected: Bool, tintBar: Color? = nil) -> some View {
        padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
            .padding(.vertical, SidebarMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                SidebarSelectionFill(isSelected: isSelected)
                if let tintBar { SidebarTintBar(color: tintBar) }
            }
            .contentShape(.rect)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Styles this view as a sidebar section header: 11 pt semibold in the
    /// secondary text style.
    func sidebarSectionHeader() -> some View {
        font(.subheadline.weight(SidebarMetrics.headerWeight))
            .emphasis(.secondary)
            .padding(.leading, SidebarMetrics.headerLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.headerMinHeight, alignment: .leading)
            .contentShape(.rect)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The leading sliver of a rounded rect inset inside the selection fill, so
/// its ends curve concentrically with the fill's corners.
private struct SidebarTintBar: View {
    let color: Color

    var body: some View {
        let inset = SidebarMetrics.tintBarInset
        color
            .clipShape(.rect(cornerRadius: SidebarMetrics.selectionCornerRadius - inset))
            .padding(inset)
            .mask(alignment: .leading) {
                Rectangle().frame(width: inset + SidebarMetrics.tintBarWidth)
            }
            .accessibilityHidden(true)
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
