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
        case .section: InfoPaneLayout.sectionWashInset
        case .nested: InfoPaneLayout.nestedWashInset
        }
    }
}

/// A collapsible section: a header led by a stub in its icon column, which,
/// while the section is expanded, reaches left into the pane's padding and
/// curls down into a bar along the section's rows.
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
        .padding(.top, InfoPaneLayout.groupVerticalPadding)
        .padding(.bottom, level == .section ? InfoPaneLayout.groupVerticalPadding : 0)
    }

    private func bracket(headerHeight: CGFloat) -> some View {
        let isPlain = InfoPaneLayout.usesPlainBar
        return InfoPaneBracketShape(
            progress: isExpanded ? 1 : 0,
            barX: level.barX,
            stubStartX: InfoPaneLayout.bracketStubStartX,
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
/// usually toggles the section. Its icon column holds the bracket's stub, so
/// its title lines up with the rows' text, unless the section's icon leads it.
struct InfoPaneSectionHeader<Accessory: View>: View {
    let title: String
    let icon: InfoPaneSectionIcon
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
    /// Follows the title and icon, such as a count.
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Button(action: action) {
            HStack(spacing: InfoPaneLayout.columnSpacing) {
                InfoPaneHeaderIcon(isExpanded: isExpanded, isDisclosable: isDisclosable)
                if InfoPaneLayout.headerIconLeads { icon }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !InfoPaneLayout.headerIconLeads { icon }
                accessory
                Spacer(minLength: 0)
                if reservesTrailingControl { OverlaidControlSpace() }
            }
            .emphasis(.secondary)
        }
        .buttonStyle(InfoPaneRowButtonStyle(suppressesWash: suppressesWash))
        .plumeID(accessibilityID, value: accessibilityValue ?? (isExpanded ? "expanded" : "collapsed"))
    }
}

extension InfoPaneSectionHeader where Accessory == InfoPaneHeaderCount {
    /// With no count, the section has nothing to disclose.
    init(
        title: String,
        icon: InfoPaneSectionIcon,
        count: Int?,
        isExpanded: Bool,
        accessibilityID: String,
        accessibilityValue: String? = nil,
        suppressesWash: Bool = false,
        reservesTrailingControl: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            icon: icon,
            isExpanded: isExpanded,
            isDisclosable: count != nil,
            accessibilityID: accessibilityID,
            accessibilityValue: accessibilityValue,
            suppressesWash: suppressesWash,
            reservesTrailingControl: reservesTrailingControl,
            action: action
        ) {
            InfoPaneHeaderCount(count: count)
        }
    }
}

/// Names a section beside its header's title.
enum InfoPaneSectionIcon: View {
    case symbol(String)
    case linear
    case gitHub

    var body: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
        case .linear:
            LinearLogo(size: InfoPaneLayout.headerLogoSize)
        case .gitHub:
            Image("GitHubMark")
                .resizable()
                .scaledToFit()
                .frame(width: InfoPaneLayout.headerLogoSize, height: InfoPaneLayout.headerLogoSize)
        }
    }
}

struct InfoPaneHeaderCount: View {
    let count: Int?

    var body: some View {
        if let count {
            Text("\(count)")
                .emphasis(.subtle)
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
                InfoPaneHeaderIcon(isExpanded: isExpanded, isDisclosable: true)
                InfoPaneHeaderTitle(title: title, count: count)
                Spacer(minLength: 0)
            }
            .emphasis(.subtle)
        }
        .buttonStyle(InfoPaneRowButtonStyle())
        .plumeID(accessibilityID, value: isExpanded ? "expanded" : "collapsed")
    }
}

/// Room for the bracket's stub, or the debug plain bar's chevron.
private struct InfoPaneHeaderIcon: View {
    let isExpanded: Bool
    let isDisclosable: Bool

    var body: some View {
        InfoPaneIcon {
            if InfoPaneLayout.usesPlainBar, isDisclosable {
                DisclosureChevron(isExpanded: isExpanded)
            } else {
                Color.clear.frame(height: 0)
            }
        }
    }
}

/// The points of a bracket. Collapsed (`progress` 0), it is a horizontal
/// stub in the header's icon column. Expanding first runs the stub left and
/// around the corner, then draws the bar down to the last row. x is measured
/// from the pane's content edge, so the bar's is negative.
nonisolated struct InfoPaneBracketGeometry: Equatable {
    /// The share of `progress` spent reaching the bar before it grows.
    static let reachShare: CGFloat = 0.35

    /// The stub's fixed right end, nil when no stub is drawn.
    let stubEnd: CGPoint?
    /// The left end of the horizontal run so far.
    let runEnd: CGPoint
    let cornerCenter: CGPoint
    let cornerRadius: CGFloat
    /// How much of the corner's quarter turn is drawn, 0 to 1.
    let cornerTurn: CGFloat
    let barStart: CGPoint
    let barEnd: CGPoint

    /// `bottom` is the section's. Without a stub, the bar starts at `stubY`.
    init(
        barX: CGFloat,
        stubStartX: CGFloat,
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
        guard drawsStub else {
            stubEnd = nil
            runEnd = CGPoint(x: barX, y: stubY)
            cornerCenter = runEnd
            self.cornerRadius = 0
            cornerTurn = 0
            barStart = runEnd
            barEnd = CGPoint(x: barX, y: stubY + fullLength * progress)
            return
        }
        let radius = max(0, min(cornerRadius, fullLength, stubStartX - barX))
        let runLength = max(0, stubStartX - barX - radius)
        let cornerLength = radius * .pi / 2
        let reached = min(1, progress / Self.reachShare) * (runLength + cornerLength)
        let barProgress = max(0, (progress - Self.reachShare) / (1 - Self.reachShare))

        stubEnd = CGPoint(x: stubEndX, y: stubY)
        runEnd = CGPoint(x: stubStartX - min(reached, runLength), y: stubY)
        cornerCenter = CGPoint(x: barX + radius, y: stubY + radius)
        self.cornerRadius = radius
        cornerTurn = cornerLength > 0 ? min(1, max(0, reached - runLength) / cornerLength) : 0
        barStart = CGPoint(x: barX, y: stubY + radius)
        barEnd = CGPoint(x: barX, y: barStart.y + (fullLength - radius) * barProgress)
    }
}

/// Drawn over the whole section, reaching left past its frame into the
/// pane's padding.
nonisolated struct InfoPaneBracketShape: Shape {
    var progress: CGFloat
    let barX: CGFloat
    let stubStartX: CGFloat
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
            stubStartX: rect.minX + stubStartX,
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
            path.addLine(to: geometry.runEnd)
            if geometry.cornerTurn > 0 {
                // From the corner's top toward the bar: counterclockwise on
                // screen, which SwiftUI's flipped space calls clockwise.
                path.addArc(
                    center: geometry.cornerCenter,
                    radius: geometry.cornerRadius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 - 90 * Double(geometry.cornerTurn)),
                    clockwise: true
                )
            }
        }
        if geometry.barEnd.y > geometry.barStart.y {
            path.move(to: geometry.barStart)
            path.addLine(to: geometry.barEnd)
        }
        return path
    }
}
