import SwiftUI

/// A section's bracket, or a subgroup's just inside it.
enum InfoPaneBracketLevel {
    case section
    case nested

    var barX: CGFloat {
        switch self {
        case .section: InfoPaneLayout.sectionBarX
        case .nested: InfoPaneLayout.nestedBarX
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .section: InfoPaneLayout.bracketCornerRadius
        case .nested: InfoPaneLayout.nestedBracketCornerRadius
        }
    }

    /// Keeps a row's hover wash clear of this level's bar.
    var washLeadingInset: CGFloat {
        switch self {
        case .section: SubagentRow.Columns.washInset
        case .nested: InfoPaneLayout.nestedWashInset
        }
    }
}

/// A collapsible section: a header whose leading stub, while the section is
/// expanded, curls down into a bar along the section's rows.
///
/// The bar and the stub sit in the pane's padding, left of the content edge,
/// so the header and rows keep the pane's columns.
struct InfoPaneBracketedSection<Header: View, Rows: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let isExpanded: Bool
    /// False for a header with nothing to disclose, which draws no stub.
    var isDisclosable = true
    var level: InfoPaneBracketLevel = .section
    @ViewBuilder let header: Header
    @ViewBuilder let rows: Rows

    @State private var headerHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            rows
        }
        .overlay(alignment: .topLeading) {
            if isDisclosable, let headerHeight {
                bracket(headerHeight: headerHeight)
            }
        }
        .environment(\.infoPaneWashLeadingInset, level.washLeadingInset)
    }

    private func bracket(headerHeight: CGFloat) -> some View {
        let isPlain = InfoPaneLayout.usesPlainBar
        return InfoPaneBracketShape(
            progress: isExpanded ? 1 : 0,
            barX: level.barX,
            stubEndX: InfoPaneLayout.bracketStubEndX,
            stubY: isPlain ? headerHeight + InfoPaneLayout.rowVerticalPadding : headerHeight / 2,
            drawsStub: !isPlain,
            cornerRadius: level.cornerRadius,
            barEndInset: InfoPaneLayout.rowVerticalPadding
        )
        .stroke(colors.divider, style: StrokeStyle(lineWidth: InfoPaneLayout.bracketLineWidth, lineCap: .round))
        .allowsHitTesting(false)
    }
}

/// The header of a collapsible section. Clicking it runs `action`, which
/// usually toggles the section.
struct InfoPaneSectionHeader<Label: View>: View {
    let isExpanded: Bool
    /// False when there is nothing to disclose, as in an empty section.
    var isDisclosable = true
    let accessibilityID: String
    var accessibilityValue: String?
    /// True while a control laid over the header is hovered.
    var suppressesWash = false
    /// Leaves room for a control laid over the trailing edge.
    var reservesTrailingControl = false
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                label
                if InfoPaneLayout.usesPlainBar, isDisclosable {
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

extension InfoPaneSectionHeader where Label == InfoPaneHeaderTitle {
    /// With no count, the section has nothing to disclose.
    init(
        title: String,
        count: Int?,
        isExpanded: Bool,
        accessibilityID: String,
        accessibilityValue: String? = nil,
        suppressesWash: Bool = false,
        reservesTrailingControl: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            isExpanded: isExpanded,
            isDisclosable: count != nil,
            accessibilityID: accessibilityID,
            accessibilityValue: accessibilityValue,
            suppressesWash: suppressesWash,
            reservesTrailingControl: reservesTrailingControl,
            action: action
        ) {
            InfoPaneHeaderTitle(title: title, count: count)
        }
    }
}

struct InfoPaneHeaderTitle: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: InfoPaneLayout.columnSpacing) {
            Text(title)
            if let count {
                Text("\(count)")
                    .emphasis(.subtle)
            }
        }
    }
}

/// The header of a collapsible group nested inside a section, such as
/// Mentioned, drawn as a nested `InfoPaneBracketedSection`.
struct InfoPaneSubgroupHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneHeaderTitle(title: title, count: count)
                if InfoPaneLayout.usesPlainBar {
                    DisclosureChevron(isExpanded: isExpanded)
                }
                Spacer(minLength: 0)
            }
            .emphasis(.subtle)
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .plumeID(accessibilityID, value: isExpanded ? "expanded" : "collapsed")
    }
}

/// The points of a bracket, with `progress` running from a horizontal stub
/// (0) to a stub that curls into a full-length bar (1). x is measured from
/// the pane's content edge, so the bar's is negative.
nonisolated struct InfoPaneBracketGeometry: Equatable {
    /// The stub's free end, nil when no stub is drawn.
    let stubEnd: CGPoint?
    let cornerStart: CGPoint
    let cornerControl: CGPoint
    let cornerEnd: CGPoint
    let barEnd: CGPoint

    /// `bottom` is the section's. Without a stub, the bar starts at `stubY`.
    init(
        barX: CGFloat,
        stubEndX: CGFloat,
        stubY: CGFloat,
        bottom: CGFloat,
        progress: CGFloat,
        drawsStub: Bool,
        cornerRadius: CGFloat,
        barEndInset: CGFloat
    ) {
        let progress = min(max(progress, 0), 1)
        let fullLength = max(0, bottom - barEndInset - stubY)
        let radius = drawsStub ? max(0, min(cornerRadius, fullLength, stubEndX - barX)) : 0
        stubEnd = drawsStub ? CGPoint(x: max(barX, stubEndX), y: stubY) : nil
        cornerStart = CGPoint(x: barX + radius * progress, y: stubY)
        cornerControl = CGPoint(x: barX, y: stubY)
        cornerEnd = CGPoint(x: barX, y: stubY + radius * progress)
        barEnd = CGPoint(x: barX, y: cornerEnd.y + (fullLength - radius) * progress)
    }
}

/// Drawn over the whole section, reaching left past its frame into the
/// pane's padding.
nonisolated struct InfoPaneBracketShape: Shape {
    var progress: CGFloat
    let barX: CGFloat
    let stubEndX: CGFloat
    let stubY: CGFloat
    let drawsStub: Bool
    let cornerRadius: CGFloat
    let barEndInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = InfoPaneBracketGeometry(
            barX: rect.minX + barX,
            stubEndX: rect.minX + stubEndX,
            stubY: rect.minY + stubY,
            bottom: rect.maxY,
            progress: progress,
            drawsStub: drawsStub,
            cornerRadius: cornerRadius,
            barEndInset: barEndInset
        )
        var path = Path()
        if let stubEnd = geometry.stubEnd {
            path.move(to: stubEnd)
            path.addLine(to: geometry.cornerStart)
            path.addQuadCurve(to: geometry.cornerEnd, control: geometry.cornerControl)
        }
        if geometry.barEnd.y > geometry.cornerEnd.y {
            path.move(to: geometry.cornerEnd)
            path.addLine(to: geometry.barEnd)
        }
        return path
    }
}
