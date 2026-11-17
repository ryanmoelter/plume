import SwiftUI

/// A skimmable map of the conversation, down one edge of the chat: one bar
/// per thing the user said or was asked, and a mark for the end.
///
/// The whole rail is one `Canvas`, in every state. Hovering magnifies the
/// bars near the pointer and shows the hovered row's text in a small glass
/// preview; clicking scrolls the chat to that row. A conversation taller
/// than the pane scrolls the map with `MinimapCatchUp`, so hovering never
/// jumps it.
struct ChatMinimap: View, ThemedView {
    @Environment(\.theme) var theme

    let outline: ChatOutline
    /// The piece ids on screen, so the reader can see where they are.
    var visiblePieceIDs: Set<String> = []
    /// Scrolls the list to a piece id.
    let onSelect: (String) -> Void
    /// Scrolls the list to the very bottom, where it starts following new
    /// content again.
    var onSelectEnd: () -> Void = {}
    /// What the composer and anything floating above it cover, matching the
    /// chat's own bottom margin.
    var bottomInset: CGFloat = 0
    /// The pane's width, which decides whether the rail has room to spread.
    var viewportWidth: CGFloat = 0
    /// How far down from the top the pointer cannot start hovering, because
    /// that stretch of a trailing rail sits beside the collapsed info pane's
    /// click targets. A hover already under way keeps following the pointer
    /// through it.
    var revealExclusionHeight: CGFloat = 0
    var side: MinimapSide = .leading
    var spacing: MinimapSpacing = .even

    /// The rail's narrowest width, and so a prompt bar's. The rail overlays
    /// the chat rather than taking a column, so this plus `edgeInset` on
    /// either side has to fit within `Dimensions.horizontalBleedPadding` —
    /// otherwise the rail crosses a bleed item's column and sits over the
    /// text.
    static let collapsedWidth: CGFloat = 8

    @State private var layout = MinimapLayout()
    @State private var tuning = MinimapTuning.shared
    @State private var height: CGFloat = 0
    /// How far the map is scrolled, in points of its own content.
    @State private var scrollOffset: CGFloat = 0
    @State private var catchUp: MinimapCatchUp?
    @State private var hoveredRow: Int?
    /// The row the preview shows, kept after the pointer leaves so the text
    /// stays put while the preview fades out.
    @State private var previewRow: Int?
    @State private var isPreviewShown = false
    /// Where the magnification is centered, in content space. Animated
    /// between rows so a snap reads as a glide.
    @State private var genieY: CGFloat = 0
    @State private var genieStrength: CGFloat = 0

    var body: some View {
        #if DEBUG
        let _ = SwitchLatencyProbe.note("minimapBody")
        #endif
        let metrics = MinimapMetrics(
            height: height,
            topMargin: dimensions.verticalPadding,
            bottomInset: bottomInset,
            contentHeight: layout.contentHeight
        )
        let visibleRows = layout.visibleRows(for: visiblePieceIDs)
        Color.clear
            .frame(width: railWidth)
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: edgeAlignment) {
                Color.clear
                    .modifier(MinimapDrawing(
                        layout: layout,
                        visibleRows: visibleRows,
                        hoveredRow: hoveredRow,
                        metrics: metrics,
                        side: side,
                        railWidth: railWidth,
                        tuning: tuning.values,
                        scrollOffset: scrollOffset,
                        genieY: genieY,
                        genieStrength: genieStrength
                    ))
                    .frame(width: canvasWidth)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: side == .leading ? .topLeading : .topTrailing) {
                preview(metrics: metrics)
            }
            .overlay(alignment: edgeAlignment) {
                hoverRegion(metrics: metrics)
            }
            .padding(side == .leading ? .leading : .trailing, railInset)
            .plumeID(AccessibilityID.chatMinimap, value: controlValue(visibleRows: visibleRows, metrics: metrics), setValue: { drive($0, metrics: metrics) })
            .onChange(of: LayoutInputs(outline: outline, spacing: spacing), initial: true) { _, inputs in
                layout = MinimapLayout(outline: inputs.outline, spacing: inputs.spacing)
            }
            // Kept where the reader is while the pointer is away. Watched
            // together with the hover so that leaving re-asserts the chat's
            // position: the chat has not moved while the pointer steered, so
            // nothing else would put the map back.
            .onChange(of: FollowDrive(
                focus: layout.focusY(visibleRows: visibleRows),
                isHovering: hoveredRow != nil,
                travel: metrics.travel,
                live: metrics.live
            ), initial: true) { _, drive in
                guard !drive.isHovering else { return }
                let target = drive.focus.map { min(max($0 - drive.live / 2, 0), drive.travel) }
                    ?? min(scrollOffset, drive.travel)
                guard target != scrollOffset else { return }
                withAnimation(.easeOut(duration: 0.2)) { scrollOffset = target }
            }
    }

    // MARK: Hover

    /// Only as wide as the rail's own footprint, out to the window edge, so
    /// a pointer that strays onto the map leaves it again with a short move.
    /// The magnified bars and the preview draw past it without taking hits.
    private func hoverRegion(metrics: MinimapMetrics) -> some View {
        Color.clear
            .frame(width: hoverWidth)
            .padding(side == .leading ? .leading : .trailing, -railInset)
            .contentShape(.rect)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard Self.tracksHover(
                        atY: point.y,
                        isTracking: hoveredRow != nil,
                        exclusionHeight: revealExclusionHeight
                    ) else { return }
                    pointerMoved(toY: point.y, metrics: metrics)
                case .ended:
                    pointerLeft()
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let row = row(atY: value.location.y, metrics: metrics) else { return }
                select(row)
            })
    }

    static func tracksHover(atY y: CGFloat, isTracking: Bool, exclusionHeight: CGFloat) -> Bool {
        isTracking || y >= exclusionHeight
    }

    private func pointerMoved(toY y: CGFloat, metrics: MinimapMetrics) {
        let absolute = MinimapCatchUp.absolute(pointerFraction: metrics.pointerFraction(atY: y))
        if metrics.travel > 0 {
            var next = catchUp ?? MinimapCatchUp(
                scroll: scrollOffset / metrics.travel,
                pointer: absolute,
                gain: tuning.values.catchUpGain
            )
            next.gain = tuning.values.catchUpGain
            if catchUp != nil { next.move(to: absolute) }
            catchUp = next
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollOffset = next.scroll * metrics.travel }
        } else {
            catchUp = nil
        }
        guard let row = row(atY: y, metrics: metrics) else { return }
        let wasHovering = hoveredRow != nil
        guard row != hoveredRow else { return }
        hoveredRow = row
        if wasHovering {
            withAnimation(.smooth(duration: tuning.values.snapDuration)) {
                genieY = layout.positions[row]
                previewRow = row
            }
        } else {
            genieY = layout.positions[row]
            previewRow = row
            withAnimation(.easeOut(duration: tuning.values.fadeInDuration)) {
                genieStrength = 1
                isPreviewShown = true
            }
        }
    }

    private func pointerLeft() {
        catchUp = nil
        hoveredRow = nil
        withAnimation(.easeOut(duration: tuning.values.fadeOutDuration)) {
            genieStrength = 0
            isPreviewShown = false
        }
    }

    private func row(atY y: CGFloat, metrics: MinimapMetrics) -> Int? {
        layout.nearestRow(toY: metrics.contentY(atY: y, scrollOffset: scrollOffset))
    }

    private func select(_ index: Int) {
        guard layout.rows.indices.contains(index) else { return }
        let row = layout.rows[index]
        if row.isEnd { onSelectEnd() } else { onSelect(row.id) }
    }

    // MARK: Preview

    private func preview(metrics: MinimapMetrics) -> some View {
        let values = tuning.values
        let row = previewRow.flatMap { layout.rows.indices.contains($0) ? layout.rows[$0] : nil }
        let y = metrics.screenY(contentY: genieY, scrollOffset: scrollOffset)
        let clampedY = min(max(y, Self.previewEdgeMargin), max(Self.previewEdgeMargin, height - bottomInset - Self.previewEdgeMargin))
        let gap = railWidth * values.genieWidthScale + Self.previewGap
        let slide = isPreviewShown ? 0 : -values.slideDistance
        return ZStack(alignment: .leading) {
            if let row, let index = previewRow {
                MinimapPreviewLabel(row: row, maxLines: Int(values.previewMaxLines))
                    .id(index)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: values.crossfadeDuration), value: previewRow)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        // A fixed width rather than a cap, so the overlay's rail-wide
        // proposal cannot squeeze it. The glass hugs the text inside it, so
        // a short prompt still gets a short pane.
        .frame(width: values.previewMaxWidth, alignment: side == .leading ? .leading : .trailing)
        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
        .offset(x: side == .leading ? gap + slide : -(gap + slide), y: clampedY)
        .opacity(isPreviewShown && row != nil ? 1 : 0)
        .allowsHitTesting(false)
    }

    private static let previewGap: CGFloat = 6
    /// How close to the pane's ends the preview's center may sit.
    private static let previewEdgeMargin: CGFloat = 18

    // MARK: Driving

    #if DEBUG
    private func controlValue(visibleRows: Set<Int>, metrics: MinimapMetrics) -> String? {
        let rows = layout.rows.enumerated().map { index, row -> [String: Any] in
            [
                "index": index,
                "label": row.label,
                "kind": row.kindName,
                "isVisible": visibleRows.contains(index),
                "isHovered": hoveredRow == index
            ]
        }
        let object: [String: Any] = [
            "side": side.rawValue,
            "spacing": spacing.rawValue,
            "scroll": metrics.travel > 0 ? Double(scrollOffset / metrics.travel) : 0,
            "rows": rows
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The control server's way in: synthetic hover never reaches
    /// `onContinuousHover`, so a driver names the row instead. `hover 3`
    /// hovers row 3, scrolling the map to it if needed; `hover 0.4` puts the
    /// pointer that far down the rail, through the catch-up; `leave` ends the
    /// hover; `click 3` and `click end` select.
    private func drive(_ command: String, metrics: MinimapMetrics) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "hover" where argument.contains("."):
            guard let fraction = Double(argument) else { return }
            pointerMoved(toY: metrics.topMargin + CGFloat(fraction) * metrics.live, metrics: metrics)
        case "hover":
            guard let index = Int(argument), layout.positions.indices.contains(index) else { return }
            var y = metrics.screenY(contentY: layout.positions[index], scrollOffset: scrollOffset)
            if y < metrics.topMargin || y > metrics.topMargin + metrics.live {
                catchUp = nil
                scrollOffset = min(max(layout.positions[index] - metrics.live / 2, 0), metrics.travel)
                y = metrics.screenY(contentY: layout.positions[index], scrollOffset: scrollOffset)
            }
            pointerMoved(toY: y, metrics: metrics)
        case "leave":
            pointerLeft()
        case "click":
            select(argument == "end" ? layout.rows.count - 1 : Int(argument) ?? -1)
        default:
            break
        }
    }
    #else
    private func controlValue(visibleRows: Set<Int>, metrics: MinimapMetrics) -> String? { nil }
    private func drive(_ command: String, metrics: MinimapMetrics) {}
    #endif

    // MARK: Geometry

    private var edgeAlignment: Alignment { side == .leading ? .leading : .trailing }

    /// Room for the most magnified bar.
    private var canvasWidth: CGFloat {
        railWidth * max(1, tuning.values.genieWidthScale) + 2
    }

    private static let edgeInset: CGFloat = 2

    /// The narrowest target the rail ever offers the pointer. The bars alone
    /// are too thin to aim at, and unlike them the target reaches the window
    /// edge — so throwing the pointer at the edge always finds it. Once the
    /// rail is wider than this the footprint takes over.
    private static let hoverWidth: CGFloat = 16

    /// The bars at their widest, and how far they sit from the window edge
    /// there. Between the two ends the rail interpolates, so it grows with
    /// the pane rather than snapping at a threshold.
    private static let spreadWidth: CGFloat = collapsedWidth * 2
    private static let spreadInset: CGFloat = 8

    /// Room left between the bars and the bleed column at full size. Nothing
    /// draws it — it is what stops the rail from crowding the conversation
    /// once both are at their full width.
    private static let spreadLeading: CGFloat = spreadInset

    private static let spreadCost: CGFloat = spreadWidth + spreadInset + spreadLeading

    /// How much of its full size the rail can afford, 0 while the bars are
    /// still within the bleed column's padding and 1 once they clear it with
    /// room to spare. Growth starts where the bars would otherwise reach into
    /// the padding beside a full-width bleed item, so widening the pane
    /// never costs the conversation anything.
    static func railSpread(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let slack = (width - dimensions.bleedWidth) / 2
        let floor = dimensions.horizontalBleedPadding
        guard slack > floor else { return 0 }
        return min((slack - floor) / (spreadCost - floor), 1)
    }

    static func railWidth(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let spread = railSpread(forViewport: width, dimensions: dimensions)
        return collapsedWidth + (spreadWidth - collapsedWidth) * spread
    }

    static func railInset(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let spread = railSpread(forViewport: width, dimensions: dimensions)
        return edgeInset + (spreadInset - edgeInset) * spread
    }

    /// What the rail draws at rest: the bars and the inset holding them off
    /// the window edge. The leading gap is left out — it is empty space over
    /// the conversation, and reaching into it made the map react while the
    /// pointer was still on the text.
    static func railFootprint(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        railWidth(forViewport: width, dimensions: dimensions)
            + railInset(forViewport: width, dimensions: dimensions)
    }

    private var railWidth: CGFloat {
        Self.railWidth(forViewport: viewportWidth, dimensions: dimensions)
    }

    private var hoverWidth: CGFloat {
        max(Self.hoverWidth, Self.railFootprint(forViewport: viewportWidth, dimensions: dimensions))
    }

    private var railInset: CGFloat {
        Self.railInset(forViewport: viewportWidth, dimensions: dimensions)
    }
}

/// The rail's vertical frame: where the map's content sits in the pane, and
/// how far it can scroll.
struct MinimapMetrics: Equatable {
    var height: CGFloat
    var topMargin: CGFloat
    var bottomInset: CGFloat
    var contentHeight: CGFloat

    /// The room the rows get: the pane less its margins, which are not part
    /// of the conversation.
    var live: CGFloat { max(1, height - 2 * topMargin - bottomInset) }
    var travel: CGFloat { max(0, contentHeight - live) }
    /// A conversation too short to fill the pane sits in its middle rather
    /// than hanging from the top.
    var centering: CGFloat { max(0, (live - contentHeight) / 2) }
    /// Below this the composer covers the pane, so nothing draws there.
    var drawableBottom: CGFloat { height - bottomInset }

    func screenY(contentY: CGFloat, scrollOffset: CGFloat) -> CGFloat {
        topMargin + centering + contentY - scrollOffset
    }

    func contentY(atY y: CGFloat, scrollOffset: CGFloat) -> CGFloat {
        y - topMargin - centering + scrollOffset
    }

    func pointerFraction(atY y: CGFloat) -> CGFloat {
        min(max((y - topMargin) / live, 0), 1)
    }
}

private struct LayoutInputs: Equatable {
    var outline: ChatOutline
    var spacing: MinimapSpacing
}

/// What returns the map to the conversation: where the chat is, whether the
/// pointer has stopped overriding it, and the room it scrolls in.
private struct FollowDrive: Equatable {
    var focus: CGFloat?
    var isHovering: Bool
    var travel: CGFloat
    var live: CGFloat
}

/// Draws every bar in one `Canvas`. Animatable over the scroll and the
/// magnification, so an animated follow or snap redraws the canvas each
/// frame without rebuilding any view.
private struct MinimapDrawing: ViewModifier, Animatable {
    let layout: MinimapLayout
    let visibleRows: Set<Int>
    let hoveredRow: Int?
    let metrics: MinimapMetrics
    let side: MinimapSide
    let railWidth: CGFloat
    let tuning: MinimapTuning.Values
    var scrollOffset: CGFloat
    var genieY: CGFloat
    var genieStrength: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(scrollOffset, AnimatablePair(genieY, genieStrength)) }
        set {
            scrollOffset = newValue.first
            genieY = newValue.second.first
            genieStrength = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !layout.positions.isEmpty else { return }
        context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, metrics.drawableBottom))))
        let radius = CGFloat(tuning.genieRadius)
        let firstVisible = layout.nearestRow(toY: metrics.contentY(atY: -radius, scrollOffset: scrollOffset)) ?? 0
        let lastVisible = layout.nearestRow(toY: metrics.contentY(atY: metrics.drawableBottom + radius, scrollOffset: scrollOffset))
            ?? layout.rows.count - 1
        let from = max(0, firstVisible - 1)
        let through = min(layout.rows.count - 1, lastVisible + 1)
        guard from <= through else { return }

        for index in from...through {
            let contentY = layout.positions[index]
            let y = metrics.screenY(contentY: contentY, scrollOffset: scrollOffset)
            if layout.spacing == .even, index + 1 < layout.positions.count, layout.tickStrengths[index] > 0 {
                let tickY = (contentY + layout.positions[index + 1]) / 2
                drawTick(in: &context, size: size, contentY: tickY, strength: layout.tickStrengths[index])
            }
            let row = layout.rows[index]
            let widthScale = scale(at: contentY, maximum: tuning.genieWidthScale)
            let thicknessScale = scale(at: contentY, maximum: tuning.genieThicknessScale)
            let thickness = MinimapLayout.rowHeight * thicknessScale
            let opacity = index == hoveredRow ? 1 : visibleRows.contains(index) ? 0.85 : 0.35
            if row.isEnd {
                let diameter = 3 * thicknessScale
                let x = side == .leading ? 0 : size.width - diameter
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y - diameter / 2, width: diameter, height: diameter)),
                    with: .color(.primary.opacity(opacity))
                )
                continue
            }
            let width = railWidth * row.widthFactor * widthScale
            let x = side == .leading ? 0 : size.width - width
            context.fill(
                Path(roundedRect: CGRect(x: x, y: y - thickness / 2, width: width, height: thickness), cornerRadius: thickness / 2),
                with: .color(.primary.opacity(opacity))
            )
        }
    }

    /// A faint mark in the gap after a row, as wide as the agent's output
    /// there was long.
    private func drawTick(in context: inout GraphicsContext, size: CGSize, contentY: CGFloat, strength: CGFloat) {
        let y = metrics.screenY(contentY: contentY, scrollOffset: scrollOffset)
        let width = railWidth * (0.2 + 0.5 * strength) * scale(at: contentY, maximum: tuning.genieWidthScale)
        let x = side == .leading ? 0 : size.width - width
        context.fill(
            Path(CGRect(x: x, y: y - 0.5, width: width, height: 1)),
            with: .color(.primary.opacity(0.1 + 0.15 * strength))
        )
    }

    private func scale(at contentY: CGFloat, maximum: Double) -> CGFloat {
        MinimapGenie.scale(
            distance: contentY - genieY,
            radius: CGFloat(tuning.genieRadius),
            maximum: CGFloat(maximum),
            strength: genieStrength
        )
    }
}

/// The hovered row's text, with a mark for anything the user did not type.
private struct MinimapPreviewLabel: View, ThemedView {
    @Environment(\.theme) var theme
    let row: MinimapRow
    let maxLines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            Text(row.label.isEmpty ? "…" : row.label)
                .lineLimit(max(1, maxLines))
                .truncationMode(.tail)
        }
        .font(typography.caption.font)
    }
}

private extension MinimapRow {
    /// Prompts draw the full rail, so they are the mark the eye lands on;
    /// what the agent asked is shorter, an interruption shorter still.
    var widthFactor: CGFloat {
        switch kind {
        case .anchor(let kind):
            switch kind {
            case .prompt, .shellCommand: 1
            case .question, .plan: 0.7
            case .interruption: 0.45
            case .response: 0.5
            }
        case .end: 0
        }
    }

    var symbol: String? {
        switch kind {
        case .anchor(let kind): kind.symbol
        case .end: "arrow.down.to.line"
        }
    }

    var kindName: String {
        switch kind {
        case .anchor(let kind):
            switch kind {
            case .prompt: "prompt"
            case .question: "question"
            case .plan: "plan"
            case .interruption: "interruption"
            case .shellCommand: "shellCommand"
            case .response: "response"
            }
        case .end: "end"
        }
    }
}
