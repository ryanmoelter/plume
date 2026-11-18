import AppKit
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
    /// Whether the map has been put where the reader is once. Until then it
    /// moves there without animating, so a newly shown map doesn't sweep.
    @State private var isPlaced = false
    @State private var hoverScroll: MinimapHoverScroll?
    /// By row id rather than index, so a row appended under a resting
    /// pointer doesn't take the hover from the row it was on.
    @State private var hoveredRowID: String?
    /// The row the preview shows, kept after the pointer leaves so the text
    /// stays put while the preview fades out.
    @State private var previewRowID: String?
    @State private var isPreviewShown = false
    /// When the pointer last left, so a return during the fade-out glides
    /// rather than jumping the half-visible magnification and preview.
    @State private var leftAt: Date?
    /// Where the magnification is centered, in content space. Animated
    /// between rows so a snap reads as a glide.
    @State private var genieY: CGFloat = 0
    @State private var genieStrength: CGFloat = 0
    @State private var clickMonitor = MinimapClickMonitor()
    @State private var presentation = MinimapPresentation()
    #if DEBUG
    @State private var controlValue: String?
    #endif

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
        let hoveredIndex = hoveredRowID.flatMap(layout.index(ofRowID:))
        Color.clear
            .frame(width: railWidth)
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: edgeAlignment) {
                Color.clear
                    .modifier(MinimapDrawing(
                        layout: layout,
                        visibleRows: visibleRows,
                        hoveredRow: hoveredIndex,
                        metrics: metrics,
                        side: side,
                        railWidth: railWidth,
                        tuning: tuning.values,
                        scrollOffset: scrollOffset,
                        centering: metrics.centering,
                        genieY: genieY,
                        genieStrength: genieStrength,
                        presentation: presentation
                    ))
                    .animation(centeringAnimation, value: metrics.centering)
                    .frame(width: canvasWidth)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                preview(metrics: metrics)
            }
            .padding(side == .leading ? .leading : .trailing, railInset)
            // After the padding, so the region reaches the pane's edge and
            // its x is measured from there.
            .overlay(alignment: edgeAlignment) {
                hoverRegion(metrics: metrics)
            }
            .onDisappear { clickMonitor.stop() }
            .plumeID(AccessibilityID.chatMinimap, value: controlValueText, setValue: { drive($0, metrics: metrics) })
            #if DEBUG
            .onChange(of: ControlValueKey(
                side: side,
                spacing: spacing,
                layout: layout,
                visibleRows: visibleRows,
                hoveredRowID: hoveredRowID,
                scrollPercent: metrics.travel > 0 ? Int((scrollOffset / metrics.travel * 100).rounded()) : 0
            ), initial: true) { _, key in
                controlValue = makeControlValue(key)
            }
            #endif
            .onChange(of: LayoutInputs(outline: outline, spacing: spacing), initial: true) { _, inputs in
                layout = MinimapLayout(outline: inputs.outline, spacing: inputs.spacing)
                keepHoverOnItsRow()
            }
            // The follow is off during a hover, so a shrinking pane would
            // leave the map drawn past its end until the pointer left.
            .onChange(of: metrics.travel) { _, travel in
                guard hoveredRowID != nil else { return }
                let next: CGFloat
                if travel > 0, var current = hoverScroll {
                    current.repin(travel: travel)
                    hoverScroll = current
                    next = current.offset
                } else {
                    hoverScroll = nil
                    next = min(max(scrollOffset, 0), travel)
                }
                guard next != scrollOffset else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrollOffset = next }
            }
            // Kept where the reader is while the pointer is away. Watched
            // together with the hover so that leaving re-asserts the chat's
            // position: the chat has not moved while the pointer steered, so
            // nothing else would put the map back.
            .onChange(of: FollowDrive(
                focus: layout.focusY(visibleRows: visibleRows),
                isHovering: hoveredRowID != nil,
                isReady: !layout.isEmpty && height > 0,
                travel: metrics.travel,
                live: metrics.live
            ), initial: true) { _, drive in
                guard !drive.isHovering, drive.isReady else { return }
                let target = drive.focus.map { min(max($0 - drive.live / 2, 0), drive.travel) }
                    ?? min(scrollOffset, drive.travel)
                guard isPlaced else {
                    scrollOffset = target
                    // Without a focus the target is only a guess, and the
                    // real one would otherwise arrive as a sweep.
                    isPlaced = drive.focus != nil
                    return
                }
                guard target != scrollOffset else { return }
                withAnimation(.easeOut(duration: 0.2)) { scrollOffset = target }
            }
    }

    // MARK: Hover

    /// Only as wide as the rail's own footprint, out to the window edge, so
    /// a pointer that strays onto the map leaves it again with a short move.
    ///
    /// Takes no hits: it sits over the chat's own scroll view and over the
    /// info pane, and a hit-testable region would swallow their clicks and
    /// the scroll wheel. A click on the hovered rail is taken by
    /// `MinimapClickMonitor` instead.
    private func hoverRegion(metrics: MinimapMetrics) -> some View {
        Color.clear
            .frame(width: hoverRegionWidth)
            .background {
                MinimapRegionProbe { clickMonitor.regionView = $0 }
            }
            .contentShape(.rect)
            .allowsHitTesting(false)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard Self.tracksHover(
                        atY: point.y,
                        isTracking: hoveredRowID != nil,
                        exclusionHeight: revealExclusionHeight,
                        drawableBottom: metrics.drawableBottom
                    ) else {
                        pointerLeft()
                        return
                    }
                    pointerMoved(toY: point.y, metrics: metrics)
                    armClick(metrics: metrics)
                case .ended:
                    pointerLeft()
                }
            }
    }

    /// The composer covers the rail below `drawableBottom`, so the pointer
    /// there is over the composer, not the map.
    static func tracksHover(atY y: CGFloat, isTracking: Bool, exclusionHeight: CGFloat, drawableBottom: CGFloat) -> Bool {
        y <= drawableBottom && (isTracking || y >= exclusionHeight)
    }

    /// A short conversation sits centered in the pane, so each row it gains
    /// moves every bar. Gliding there keeps a hovered bar under the pointer.
    private var centeringAnimation: Animation? {
        isPlaced ? .smooth(duration: tuning.values.snapDuration) : nil
    }

    /// Lets a click select the hovered row, but only where it lands on the
    /// rail and not on something else's target. The click's own point is
    /// checked, not the last hover's.
    private func armClick(metrics: MinimapMetrics) {
        guard let id = hoveredRowID else {
            clickMonitor.onClick = nil
            return
        }
        let side = side
        let reach = MinimapClickZone.reach(inset: railInset, barWidth: hoveredBarWidth)
        let exclusionHeight = revealExclusionHeight
        let drawableBottom = metrics.drawableBottom
        clickMonitor.accepts = { point, regionWidth in
            MinimapClickZone.accepts(
                distanceFromEdge: side == .leading ? point.x : regionWidth - point.x,
                y: point.y,
                reach: reach,
                exclusionHeight: exclusionHeight,
                drawableBottom: drawableBottom
            )
        }
        clickMonitor.onClick = { select(id: id) }
        clickMonitor.start()
    }

    private func pointerMoved(toY y: CGFloat, metrics: MinimapMetrics) {
        let absolute = MinimapCatchUp.absolute(pointerFraction: metrics.pointerFraction(atY: y))
        let gain = tuning.values.catchUpGain
        if metrics.travel > 0 {
            var next: MinimapHoverScroll
            if var current = hoverScroll {
                current.move(to: absolute, pointerY: y, travel: metrics.travel, gain: gain)
                next = current
            } else {
                // The follow may still be animating, so start from what is
                // drawn rather than where it is headed.
                next = MinimapHoverScroll(
                    offset: presentation.scrollOffset ?? scrollOffset,
                    travel: metrics.travel,
                    pointer: absolute,
                    gain: gain,
                    entryY: y,
                    deadZoneRadius: tuning.values.deadZoneRadius
                )
            }
            hoverScroll = next
            if next.offset != scrollOffset {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrollOffset = next.offset }
            }
        } else {
            hoverScroll = nil
        }
        let centering = presentation.centering ?? metrics.centering
        let contentY = y - metrics.topMargin - centering + scrollOffset
        guard let index = layout.nearestRow(toY: contentY) else { return }
        let id = layout.rows[index].id
        guard id != hoveredRowID else { return }
        let isFadingOut = leftAt.map { Date().timeIntervalSince($0) < tuning.values.fadeOutDuration } ?? false
        let wasShowing = hoveredRowID != nil || isFadingOut
        hoveredRowID = id
        leftAt = nil
        if wasShowing {
            withAnimation(.smooth(duration: tuning.values.snapDuration)) {
                genieY = layout.positions[index]
                previewRowID = id
            }
        } else {
            genieY = layout.positions[index]
            previewRowID = id
        }
        if genieStrength < 1 || !isPreviewShown {
            withAnimation(.easeOut(duration: tuning.values.fadeInDuration)) {
                genieStrength = 1
                isPreviewShown = true
            }
        }
    }

    private func pointerLeft() {
        guard hoveredRowID != nil || hoverScroll != nil else { return }
        hoverScroll = nil
        hoveredRowID = nil
        leftAt = Date()
        clickMonitor.stop()
        withAnimation(.easeOut(duration: tuning.values.fadeOutDuration)) {
            genieStrength = 0
            isPreviewShown = false
        }
    }

    /// After the rows change, moves the magnification to wherever the
    /// hovered row now sits, or ends the hover if the row is gone.
    private func keepHoverOnItsRow() {
        guard let id = hoveredRowID else { return }
        guard let index = layout.index(ofRowID: id) else {
            pointerLeft()
            return
        }
        guard genieY != layout.positions[index] else { return }
        withAnimation(.smooth(duration: tuning.values.snapDuration)) { genieY = layout.positions[index] }
    }

    private func select(id: String) {
        guard let index = layout.index(ofRowID: id) else { return }
        let row = layout.rows[index]
        if row.isEnd { onSelectEnd() } else { onSelect(row.id) }
    }

    // MARK: Preview

    private func preview(metrics: MinimapMetrics) -> some View {
        let values = tuning.values
        let row = previewRowID.flatMap(layout.index(ofRowID:)).map { layout.rows[$0] }
        let y = metrics.screenY(contentY: genieY, scrollOffset: scrollOffset)
        let clampedY = min(max(y, Self.previewEdgeMargin), max(Self.previewEdgeMargin, height - bottomInset - Self.previewEdgeMargin))
        let gap = railWidth * values.genieWidthScale + Self.previewGap
        let slide = isPreviewShown ? 0 : -values.slideDistance
        let width = Self.previewWidth(
            maximum: values.previewMaxWidth,
            viewportWidth: viewportWidth,
            railInset: railInset,
            gap: gap
        )
        // In the rail's own space, whose x runs from the rail's leading edge.
        // The preview always opens toward the chat.
        let x = side == .leading ? gap + slide : railWidth - gap - slide - width
        return ZStack(alignment: .leading) {
            if let row {
                MinimapPreviewLabel(row: row, maxLines: Int(values.previewMaxLines))
                    .id(row.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: values.crossfadeDuration), value: previewRowID)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        // A fixed width rather than a cap, so the overlay's rail-wide
        // proposal cannot squeeze it. The glass hugs the text inside it, so
        // a short prompt still gets a short pane.
        .frame(width: width, alignment: side == .leading ? .leading : .trailing)
        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
        .offset(x: x, y: clampedY)
        .animation(centeringAnimation, value: metrics.centering)
        .opacity(isPreviewShown && row != nil ? 1 : 0)
        .allowsHitTesting(false)
    }

    private static let previewGap: CGFloat = 6
    /// Kept between the preview and the pane's far edge.
    private static let previewFarMargin: CGFloat = 8

    /// The preview's width, capped so it stays inside the chat pane.
    static func previewWidth(maximum: CGFloat, viewportWidth: CGFloat, railInset: CGFloat, gap: CGFloat) -> CGFloat {
        let room = viewportWidth - railInset - gap - previewFarMargin
        return max(0, min(maximum, room))
    }
    /// How close to the pane's ends the preview's center may sit.
    private static let previewEdgeMargin: CGFloat = 18

    // MARK: Driving

    #if DEBUG
    private var controlValueText: String? { controlValue }

    private func makeControlValue(_ key: ControlValueKey) -> String? {
        let rows = key.layout.rows.enumerated().map { index, row -> [String: Any] in
            [
                "index": index,
                "label": row.label,
                "kind": row.kindName,
                "isVisible": key.visibleRows.contains(index),
                "isHovered": key.hoveredRowID == row.id
            ]
        }
        let object: [String: Any] = [
            "side": key.side.rawValue,
            "spacing": key.spacing.rawValue,
            "scroll": Double(key.scrollPercent) / 100,
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
            armClick(metrics: metrics)
        case "hover":
            guard let index = Int(argument), layout.positions.indices.contains(index) else { return }
            var y = metrics.screenY(contentY: layout.positions[index], scrollOffset: scrollOffset)
            if y < metrics.topMargin || y > metrics.topMargin + metrics.live {
                hoverScroll = nil
                scrollOffset = min(max(layout.positions[index] - metrics.live / 2, 0), metrics.travel)
                y = metrics.screenY(contentY: layout.positions[index], scrollOffset: scrollOffset)
            }
            pointerMoved(toY: y, metrics: metrics)
            armClick(metrics: metrics)
        case "leave":
            pointerLeft()
        case "click":
            let index = argument == "end" ? layout.rows.count - 1 : Int(argument) ?? -1
            guard layout.rows.indices.contains(index) else { return }
            select(id: layout.rows[index].id)
        default:
            break
        }
    }
    #else
    private var controlValueText: String? { nil }
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

    /// Widens while a row is hovered to cover the magnified bars, so the
    /// pointer can reach and click the widest of them without leaving.
    private var hoverRegionWidth: CGFloat {
        guard hoveredRowID != nil else { return hoverWidth }
        let widest = railWidth * max(1, tuning.values.genieWidthScale)
        return max(hoverWidth, MinimapClickZone.reach(inset: railInset, barWidth: widest))
    }

    /// The hovered bar's length at full magnification. The end row draws a
    /// dot rather than a bar.
    private var hoveredBarWidth: CGFloat {
        guard let index = hoveredRowID.flatMap(layout.index(ofRowID:)) else { return 0 }
        let row = layout.rows[index]
        switch row.mark {
        case .bar(let factor): return railWidth * factor * max(1, tuning.values.genieWidthScale)
        case .dot: return MinimapDrawing.dotDiameter * max(1, tuning.values.genieThicknessScale)
        case .end: return MinimapDrawing.endDiameter * max(1, tuning.values.genieThicknessScale)
        }
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
    /// The rows and the pane's height have both arrived.
    var isReady: Bool
    var travel: CGFloat
    var live: CGFloat
}

#if DEBUG
/// What the control value is a function of. Kept small, so a pointer move
/// that changes none of it rebuilds nothing.
private struct ControlValueKey: Equatable {
    var side: MinimapSide
    var spacing: MinimapSpacing
    var layout: MinimapLayout
    var visibleRows: Set<Int>
    var hoveredRowID: String?
    var scrollPercent: Int
}
#endif

/// Takes a left click on the hovered rail before it reaches the chat. A
/// monitor rather than a hit-testable view: the rail lies over the chat's
/// scroll view and its bleed padding, and a view there would take the
/// scroll wheel and every click meant for them. Running only while the
/// pointer is over the rail, and armed only where a click belongs to it.
@MainActor
private final class MinimapClickMonitor {
    /// The hover region's own view, which a click's point is measured in.
    weak var regionView: NSView?
    /// Whether a point in the region, given the region's width, is on the
    /// hovered rail.
    var accepts: ((CGPoint, CGFloat) -> Bool)?
    /// Nil wherever a click should reach the chat instead.
    var onClick: (() -> Void)?
    private var monitor: Any?
    /// Set from a taken mouse-down to its mouse-up, so the drag between
    /// them can't start a text selection in the chat.
    private var swallowsMouseUp = false
    private var stopsAfterMouseUp = false

    func start() {
        stopsAfterMouseUp = false
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let region = self.regionView, event.window === region.window else { return event }
            switch event.type {
            case .leftMouseDragged:
                return self.swallowsMouseUp ? nil : event
            case .leftMouseUp:
                guard self.swallowsMouseUp else { return event }
                self.swallowsMouseUp = false
                if self.stopsAfterMouseUp { self.removeMonitor() }
                return nil
            default:
                break
            }
            guard let onClick = self.onClick,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  self.accepts?(region.convert(event.locationInWindow, from: nil), region.bounds.width) == true,
                  MinimapClickZone.isChatContent(region.window?.contentView?.superview?.hitTest(event.locationInWindow))
            else { return event }
            self.swallowsMouseUp = true
            onClick()
            return nil
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Waits for the mouse-up of a click already taken, so a pointer that
    /// presses and leaves the rail doesn't hand the chat a drag.
    func stop() {
        onClick = nil
        if swallowsMouseUp {
            stopsAfterMouseUp = true
        } else {
            removeMonitor()
        }
    }

    private func removeMonitor() {
        stopsAfterMouseUp = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Gives `MinimapClickMonitor` the hover region's own view, flipped so its
/// y runs down like the region's SwiftUI space. Takes no hits.
private struct MinimapRegionProbe: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        onView(view)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What the canvas last drew. The follow and the centering animate, and
/// their model values are where they are headed, so a hover starting mid
/// animation reads these to map the pointer onto what is on screen. A plain
/// class, not observed: the canvas writes it as it draws.
private final class MinimapPresentation {
    var scrollOffset: CGFloat?
    var centering: CGFloat?
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
    /// Drawn from here rather than `metrics`, so it animates.
    var centering: CGFloat
    var genieY: CGFloat
    var genieStrength: CGFloat
    let presentation: MinimapPresentation

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(scrollOffset, centering), AnimatablePair(genieY, genieStrength)) }
        set {
            scrollOffset = newValue.first.first
            centering = newValue.first.second
            genieY = newValue.second.first
            genieStrength = newValue.second.second
        }
    }

    private func screenY(contentY: CGFloat) -> CGFloat {
        metrics.topMargin + centering + contentY - scrollOffset
    }

    private func contentY(atY y: CGFloat) -> CGFloat {
        y - metrics.topMargin - centering + scrollOffset
    }

    func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, size in
                presentation.scrollOffset = scrollOffset
                presentation.centering = centering
                draw(in: &context, size: size)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !layout.positions.isEmpty else { return }
        context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, metrics.drawableBottom))))
        let radius = CGFloat(tuning.genieRadius)
        let firstVisible = layout.nearestRow(toY: contentY(atY: -radius)) ?? 0
        let lastVisible = layout.nearestRow(toY: contentY(atY: metrics.drawableBottom + radius))
            ?? layout.rows.count - 1
        let from = max(0, firstVisible - 1)
        let through = min(layout.rows.count - 1, lastVisible + 1)
        guard from <= through else { return }

        for index in from...through {
            let contentY = layout.positions[index]
            let y = screenY(contentY: contentY)
            if layout.spacing == .proportional, index + 1 < layout.positions.count, layout.rows[index].trailingWeight > 0 {
                drawResponseBox(in: &context, size: size, from: contentY, to: layout.positions[index + 1])
            }
            let row = layout.rows[index]
            let thicknessScale = scale(at: contentY, maximum: tuning.genieThicknessScale)
            let color = GraphicsContext.Shading.color(
                .primary.opacity(index == hoveredRow ? 1 : visibleRows.contains(index) ? 0.85 : 0.35)
            )
            switch row.mark {
            case .end:
                drawEndMark(in: &context, size: size, y: y, scale: thicknessScale, shading: color)
            case .dot:
                drawDot(in: &context, size: size, y: y, diameter: Self.dotDiameter * thicknessScale, shading: color)
            case .bar(let factor):
                let thickness = MinimapLayout.rowHeight * thicknessScale
                let width = railWidth * factor * scale(at: contentY, maximum: tuning.genieWidthScale)
                let x = side == .leading ? 0 : size.width - width
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: y - thickness / 2, width: width, height: thickness), cornerRadius: thickness / 2),
                    with: color
                )
            }
        }
    }

    /// A prompt the user didn't type: round, so magnified it grows into a
    /// bigger dot and never reads as a prompt's bar.
    static let dotDiameter: CGFloat = 3.5
    static let endDiameter: CGFloat = 3

    private func drawDot(in context: inout GraphicsContext, size: CGSize, y: CGFloat, diameter: CGFloat, shading: GraphicsContext.Shading) {
        let x = side == .leading ? 0 : size.width - diameter
        context.fill(Path(ellipseIn: CGRect(x: x, y: y - diameter / 2, width: diameter, height: diameter)), with: shading)
    }

    /// The end of the conversation.
    private func drawEndMark(in context: inout GraphicsContext, size: CGSize, y: CGFloat, scale: CGFloat, shading: GraphicsContext.Shading) {
        drawDot(in: &context, size: size, y: y, diameter: Self.endDiameter * scale, shading: shading)
    }

    /// A soft box over the gap between two rows, where the agent's reply to
    /// the first sits. Fainter than any bar, and held clear of both rows'
    /// marks at whatever size the magnification draws them.
    private func drawResponseBox(in context: inout GraphicsContext, size: CGSize, from top: CGFloat, to bottom: CGFloat) {
        let clearance: (CGFloat) -> CGFloat = { contentY in
            MinimapLayout.rowHeight * scale(at: contentY, maximum: tuning.genieThicknessScale) / 2 + 1.5
        }
        let boxTop = screenY(contentY: top) + clearance(top)
        let boxBottom = screenY(contentY: bottom) - clearance(bottom)
        let height = boxBottom - boxTop
        guard height >= 1.5 else { return }
        let nearest = min(max(genieY, top), bottom)
        let width = railWidth * 0.75 * scale(at: nearest, maximum: tuning.genieWidthScale)
        let x = side == .leading ? 0 : size.width - width
        context.fill(
            Path(roundedRect: CGRect(x: x, y: boxTop, width: width, height: height), cornerRadius: min(2, height / 2)),
            with: .color(.primary.opacity(0.07))
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

private enum MinimapMark {
    /// A bar this fraction of the rail wide.
    case bar(CGFloat)
    case dot
    case end
}

private extension MinimapRow {
    /// Typed prompts draw the full rail, so they are the mark the eye lands
    /// on. Anything else that opens a turn draws a dot.
    var mark: MinimapMark {
        switch kind {
        case .anchor(let kind):
            switch kind {
            case .prompt: .bar(1)
            case .response: .bar(0.5)
            case .question, .plan, .interruption, .shellCommand: .dot
            }
        case .end: .end
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
