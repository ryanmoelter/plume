import SwiftUI

/// A collapsible section: a header whose leading stub, while the section is
/// expanded, curls down into a bar along the section's rows.
///
/// The header and the rows share the pane's content edge; the stub and the
/// bar sit in the gutter to its left, `InfoPaneLayout.sectionGutter` wide.
struct InfoPaneBracketedSection<Header: View, Rows: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let isExpanded: Bool
    /// False for a header with nothing to disclose, which draws no stub.
    var isDisclosable = true
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
    }

    private func bracket(headerHeight: CGFloat) -> some View {
        let isPlain = InfoPaneLayout.usesPlainBar
        let shape = { (part: InfoPaneBracketShape.Part) in
            InfoPaneBracketShape(
                part: part,
                progress: isExpanded ? 1 : 0,
                stubY: isPlain ? headerHeight + InfoPaneLayout.rowVerticalPadding : headerHeight / 2,
                drawsStub: !isPlain,
                cornerRadius: InfoPaneLayout.bracketCornerRadius,
                stubGap: InfoPaneLayout.bracketStubGap,
                barEndInset: InfoPaneLayout.rowVerticalPadding,
                lineWidth: InfoPaneLayout.bracketLineWidth
            )
        }
        let style = StrokeStyle(lineWidth: InfoPaneLayout.bracketLineWidth, lineCap: .round)
        return ZStack {
            shape(.stub).stroke(colors.surface(.subtle), style: style)
            shape(.bar).stroke(colors.divider, style: style)
        }
        .frame(width: InfoPaneLayout.sectionGutter)
        .offset(x: -InfoPaneLayout.sectionGutter)
        .allowsHitTesting(false)
        .animation(InfoPaneLayout.sectionAnimation, value: isExpanded)
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

/// A collapsible group nested inside a section, such as Mentioned. Its glyph
/// is a small copy of the section's stub that curls down while it is open,
/// so its rows keep the section's icon column.
struct InfoPaneSubgroupHeader: View, ThemedView {
    @Environment(\.theme) var theme

    let title: String
    let count: Int
    let isExpanded: Bool
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneIcon { glyph }
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

    @ViewBuilder
    private var glyph: some View {
        if InfoPaneLayout.usesPlainBar {
            // Holds the first column without filling the row's height.
            DisclosureChevron(isExpanded: false).hidden()
        } else {
            let size = InfoPaneLayout.subgroupGlyphSize
            InfoPaneBracketShape(
                part: .whole,
                progress: isExpanded ? 1 : 0,
                stubY: size.height / 2,
                drawsStub: true,
                cornerRadius: InfoPaneLayout.subgroupGlyphCornerRadius,
                stubGap: 0,
                barEndInset: 0,
                lineWidth: InfoPaneLayout.bracketLineWidth
            )
            .stroke(colors.surface(.subtle), style: StrokeStyle(lineWidth: InfoPaneLayout.bracketLineWidth, lineCap: .round))
            .frame(width: size.width, height: size.height)
            .animation(InfoPaneLayout.sectionAnimation, value: isExpanded)
        }
    }
}

/// The points of a section's bracket, with `progress` running from a
/// horizontal stub (0) to a stub that curls into a full-length bar (1).
nonisolated struct InfoPaneBracketGeometry: Equatable {
    let barX: CGFloat
    /// The stub's free end, nil when no stub is drawn.
    let stubEnd: CGPoint?
    let cornerStart: CGPoint
    let cornerControl: CGPoint
    let cornerEnd: CGPoint
    let barEnd: CGPoint

    /// `rect` is the gutter, as tall as the whole section. Without a stub,
    /// the bar starts at `stubY`.
    init(
        rect: CGRect,
        stubY: CGFloat,
        progress: CGFloat,
        lineWidth: CGFloat,
        drawsStub: Bool,
        cornerRadius: CGFloat,
        stubGap: CGFloat,
        barEndInset: CGFloat
    ) {
        let progress = min(max(progress, 0), 1)
        let barX = rect.minX + lineWidth / 2
        let fullLength = max(0, rect.maxY - barEndInset - stubY)
        let radius = drawsStub ? min(cornerRadius, fullLength) : 0
        self.barX = barX
        stubEnd = drawsStub ? CGPoint(x: max(barX, rect.maxX - stubGap), y: stubY) : nil
        cornerStart = CGPoint(x: barX + radius * progress, y: stubY)
        cornerControl = CGPoint(x: barX, y: stubY)
        cornerEnd = CGPoint(x: barX, y: stubY + radius * progress)
        barEnd = CGPoint(x: barX, y: cornerEnd.y + (fullLength - radius) * progress)
    }
}

nonisolated struct InfoPaneBracketShape: Shape {
    enum Part {
        /// The stub and its corner.
        case stub
        case bar
        case whole
    }

    let part: Part
    var progress: CGFloat
    let stubY: CGFloat
    let drawsStub: Bool
    let cornerRadius: CGFloat
    let stubGap: CGFloat
    let barEndInset: CGFloat
    let lineWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = InfoPaneBracketGeometry(
            rect: rect,
            stubY: stubY,
            progress: progress,
            lineWidth: lineWidth,
            drawsStub: drawsStub,
            cornerRadius: cornerRadius,
            stubGap: stubGap,
            barEndInset: barEndInset
        )
        var path = Path()
        if part != .bar, let stubEnd = geometry.stubEnd {
            path.move(to: stubEnd)
            path.addLine(to: geometry.cornerStart)
            path.addQuadCurve(to: geometry.cornerEnd, control: geometry.cornerControl)
        }
        if part != .stub, geometry.barEnd.y > geometry.cornerEnd.y {
            path.move(to: geometry.cornerEnd)
            path.addLine(to: geometry.barEnd)
        }
        return path
    }
}
