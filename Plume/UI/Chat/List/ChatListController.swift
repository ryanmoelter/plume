import AppKit
import os
import SwiftUI

/// What the custom chat list is asked to draw, as one value so an update that
/// changes nothing can be told from one that does.
struct ChatListInputs: Equatable {
    var pieces: [ChatPiece] = []
    var tabID: UUID?
    /// The inline info pane, after the last message. Nil when the pane is
    /// presented elsewhere.
    var infoPane: InfoPaneFacts?
    /// Room above the first message for whatever floats over the list's top
    /// edge.
    var leadingInset: CGFloat = 0
    /// Room the rows leave beside them at the list's trailing edge, for the
    /// pinned info pane. Rows lay out in what is left.
    var sideReserve: CGFloat = 0
    var animate = true
    /// The room the floating composer covers, plus the padding below the
    /// last message.
    var trailingInset: CGFloat = 0
    var chatFontSize: CGFloat = AppSettings.defaultChatFontSize
    var workStartedAt: Date?
    /// Resolves relative paths in a clicked link.
    var linkDirectory: URL?
    var arrivals: Set<String> = []
}

/// The handle `ChatMessageList` keeps to ask the custom list for a scroll.
///
/// A reference the controller registers itself on, so the SwiftUI side can
/// hold it in `@State` before the view exists.
@MainActor
final class ChatListCommands {
    weak var controller: ChatListController?

    func jump(to pieceID: String) {
        controller?.scroll(to: .item(pieceID), animated: true)
    }

    func scrollToBottom(animated: Bool) {
        controller?.scroll(to: .bottom, animated: animated)
    }

    /// Pins a just-sent prompt to the top of the viewport. See
    /// `ChatLayoutModel`'s slack.
    func pin(pieceID: String) {
        controller?.pin(pieceID: pieceID)
    }

    /// Keeps the piece where it is on screen through the next change, if
    /// the reader can see it. See `ChatListController.hold`.
    func hold(pieceID: String, overridingFollow: Bool) {
        controller?.hold(pieceID: pieceID, overridingFollow: overridingFollow)
    }
}

/// Owns the custom chat list: the scroll view, the document view, the layout
/// model, the hosts that draw realized items, and the animator.
///
/// Everything that moves the viewport goes through `layoutPass`, which
/// resolves one offset policy per pass — a programmatic scroll in flight,
/// following the bottom, or holding the reader's place — commits the
/// document size, and only then sets the offset. Nothing else writes it.
@MainActor
final class ChatListController: NSObject {
    let scrollView = NSScrollView()
    let documentView = ChatListDocumentView()

    var onOpenSubagent: (SubagentTranscript) -> Void = { _ in }
    var onOpenSideChat: () -> Void = {}
    var onToggleAgentMessage: (String) -> Void = { _ in }
    /// Nil makes plan rows non-clickable. It sits outside the `inputs` diff,
    /// so a change between nil and non-nil refreshes mounted rows itself.
    var onOpenPlan: (() -> Void)? {
        didSet {
            guard (oldValue == nil) != (onOpenPlan == nil) else { return }
            refreshRoots(Set(hosts.keys))
            documentView.needsLayout = true
        }
    }
    var onVisiblePieceIDs: (Set<String>) -> Void = { _ in }
    var onDetachedChange: (Bool) -> Void = { _ in }
    var revealModel: ChatRevealModel?
    /// Set on every update. Assigning it restages the rows itself when what
    /// a row draws from it has changed, because a fork marker can appear on a
    /// transcript change that leaves every piece untouched — and an untouched
    /// piece is not otherwise restaged.
    var redoContext: MessageRedoContext? {
        didSet {
            guard redoContext?.renderedState != oldValue?.renderedState else { return }
            refreshRoots(Set(hosts.keys))
        }
    }

    private(set) var inputs = ChatListInputs()
    private var model = ChatLayoutModel()
    private var items: [String: Item] = [:]
    private var hosts: [String: Host] = [:]
    private var pool: [NSHostingView<AnyView>] = []
    private var pendingMeasurements: [Measurement] = []
    private lazy var animator = ChatListAnimator(view: documentView)

    /// Whether the viewport tracks the bottom as content grows. Only a
    /// scroll the reader made can turn it off; a scroll the list made never
    /// counts.
    private var isFollowing = true
    /// How far above the bottom the reader settled while still counting as
    /// following, so growth keeps that gap rather than snapping it shut.
    private var followDistance: CGFloat = 0
    private var wheelMonitor: Any?
    /// Which way the trackpad gesture in flight is going, decided once as it
    /// begins so a diagonal drift cannot hand it back and forth mid-gesture.
    private var wheelGestureIsVertical: Bool?
    private var isDetached = false
    /// The item under the viewport's top edge and how far into it the reader
    /// is, captured whenever the reader scrolls, so heights changing above
    /// them move nothing they can see.
    private var readerAnchor: (id: String, distance: CGFloat)?
    private var easedOffset: CGFloat?
    private var isOwnScroll = false
    private var isLayingOut = false
    /// The offset the policy last asked for. A pass writes the offset only
    /// when its policy asks for a different one, so a reader mid-gesture —
    /// rubber-banding past the end included — is left where they are.
    private var lastResolvedOffset: CGFloat?
    private var consumedArrivals: Set<String> = []
    private var arriving: Set<String> = []
    /// Pieces that fade and collapse in place of vanishing — a working
    /// indicator, or the rows a collapsing agent message hides — each keyed
    /// to the nearest piece above it that stays.
    private var departing: [String: Departure] = [:]
    private var publishedVisibleIDs: Set<String> = []
    private var pendingPin: String?

    private static let leadingInsetID = "plume.leading.inset"
    private static let dockID = "plume.trailing.dock"
    private static let infoPaneID = "plume.trailing.infoPane"
    private static let insetEaseKey = "plume.trailingInset"
    private static let poolLimit = 40

    /// About a line or two of body text left showing above a freshly pinned
    /// prompt. Scaled to the chat's own font size rather than a fixed point,
    /// so it still reads as "a line or two" at a size other than the default.
    private var pinTopInset: CGFloat { inputs.chatFontSize * 2.5 }

    private enum Item {
        case leadingInset
        case piece(ChatPiece)
        case dock
        case infoPane
    }

    private struct Host {
        let view: NSHostingView<AnyView>
        let state: ChatListItemState
        let generation: Int
    }

    private struct Departure {
        let piece: ChatPiece
        let after: String?
        /// Its place in the pieces it left, so several departing after the
        /// same piece keep their order.
        let order: Int
        var isCollapsing = false
    }

    private struct Measurement {
        let id: String
        let height: CGFloat
        let width: CGFloat
        let generation: Int
    }

    override init() {
        super.init()
        documentView.controller = self
        documentView.wantsLayer = true
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged), name: NSView.frameDidChangeNotification, object: clip
        )
        animator.onTick = { [weak self] now in self?.tick(at: now) }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.routeWheel(event) ?? event
        }
    }

    /// Breaks the display link's hold on the animator; nothing else keeps
    /// the controller alive once its view is gone.
    func tearDown() {
        animator.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    // MARK: - Nested scroll views

    /// A row's own scroll view takes every wheel event over it, including a
    /// vertical one it has no use for: a code block scrolls sideways only,
    /// and AppKit still lets it swallow the scroll that should move the
    /// list. A vertical gesture over a row scroller with no vertical room
    /// goes to the list instead. One that can scroll vertically, a disclosed
    /// tool result, keeps what it is given.
    private func routeWheel(_ event: NSEvent) -> NSEvent? {
        guard let window = scrollView.window, event.window === window,
              let hit = window.contentView?.hitTest(event.locationInWindow),
              hit.isDescendant(of: documentView),
              let inner = nearestScrollView(above: hit)
        else { return event }
        let room = (inner.documentView?.frame.height ?? 0) - inner.contentView.bounds.height
        guard room <= 0.5 else { return event }
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            wheelGestureIsVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        }
        defer {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                wheelGestureIsVertical = nil
            }
        }
        guard wheelGestureIsVertical == true else { return event }
        scrollView.scrollWheel(with: event)
        return nil
    }

    /// The closest scroll view between a hit view and the list's own, or nil
    /// when the hit lands straight on the list.
    private func nearestScrollView(above view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let view = current, view !== scrollView {
            if let scroll = view as? NSScrollView { return scroll }
            current = view.superview
        }
        return nil
    }

    // MARK: - Inputs

    func update(_ new: ChatListInputs) {
        let old = inputs
        inputs = new
        var stale: Set<String> = []

        if new.pieces != old.pieces || new.tabID != old.tabID
            || (new.infoPane == nil) != (old.infoPane == nil)
            || (new.leadingInset == 0) != (old.leadingInset == 0) {
            stale.formUnion(rebuildItems(previous: old.pieces, allowsDepartures: new.tabID == old.tabID))
        }
        if new.trailingInset != old.trailingInset {
            if new.animate, model.viewportHeight > 0, documentView.window != nil {
                animator.ease(Self.insetEaseKey, from: model.trailingInset, to: new.trailingInset, duration: 0.2)
            } else {
                model.trailingInset = new.trailingInset
            }
        }
        if new.sideReserve != old.sideReserve, new.animate, documentView.window != nil {
            slideFromPreviousColumn(by: (new.sideReserve - old.sideReserve) / 2)
        }
        if new.animate != old.animate {
            if !new.animate {
                for key in animator.eases.keys { animator.cancelEase(key) }
                if !departing.isEmpty {
                    departing.removeAll()
                    _ = rebuildItems(previous: new.pieces)
                }
                model.snapDisplayHeights()
                model.trailingInset = new.trailingInset
                for host in hosts.values { host.state.containerHeight = nil; host.view.alphaValue = 1 }
                arriving.removeAll()
            } else {
                for (id, host) in hosts { host.state.containerHeight = model.displayHeight(of: id) }
            }
        }
        if new.chatFontSize != old.chatFontSize || new.workStartedAt != old.workStartedAt
            || new.linkDirectory != old.linkDirectory {
            stale.formUnion(hosts.keys)
        }
        if new.infoPane != old.infoPane {
            stale.insert(Self.infoPaneID)
        }
        if new.leadingInset != old.leadingInset {
            stale.insert(Self.leadingInsetID)
        }
        refreshRoots(stale)
        documentView.needsLayout = true
    }

    /// Returns the ids of realized pieces whose content changed.
    private func rebuildItems(previous: [ChatPiece], allowsDepartures: Bool = false) -> Set<String> {
        var next: [String: Item] = [:]
        var layoutItems: [ChatLayoutItem] = []
        layoutItems.reserveCapacity(inputs.pieces.count + 3)
        let width = max(1, model.measurementWidth)
        if inputs.leadingInset > 0 {
            next[Self.leadingInsetID] = .leadingInset
            layoutItems.append(ChatLayoutItem(id: Self.leadingInsetID, estimatedHeight: inputs.leadingInset))
        }
        for piece in inputs.pieces {
            next[piece.id] = .piece(piece)
        }
        if allowsDepartures { startDepartures(from: previous, staying: next) }
        var returned: [String] = []
        for id in departing.keys where next[id] != nil {
            departing[id] = nil
            animator.cancelEase(id)
            hosts[id]?.view.alphaValue = 1
            returned.append(id)
        }
        var departuresAfter: [String?: [Departure]] = [:]
        for departure in departing.values {
            let after = departure.after.flatMap { next[$0] == nil ? nil : $0 }
            departuresAfter[after, default: []].append(departure)
        }
        func appendDepartures(after id: String?) {
            for piece in (departuresAfter[id] ?? []).sorted(by: { $0.order < $1.order }).map(\.piece) {
                next[piece.id] = .piece(piece)
                // Its inset is folded into the collapsing height, so the
                // content below closes up continuously.
                layoutItems.append(ChatLayoutItem(id: piece.id, estimatedHeight: 0))
            }
        }
        for piece in inputs.pieces {
            layoutItems.append(ChatLayoutItem(
                id: piece.id,
                topInset: piece.paysInsetOutside ? piece.topInset : 0,
                bottomInset: piece.bottomInset,
                estimatedHeight: ChatPieceEstimate.height(of: piece, width: width)
            ))
            appendDepartures(after: piece.id)
        }
        appendDepartures(after: nil)
        if inputs.tabID != nil {
            // The dock needs a click, so it stays above the composer; the
            // info pane folds behind it.
            next[Self.dockID] = .dock
            layoutItems.append(ChatLayoutItem(id: Self.dockID, estimatedHeight: 0))
            if inputs.infoPane != nil {
                next[Self.infoPaneID] = .infoPane
                layoutItems.append(ChatLayoutItem(id: Self.infoPaneID, estimatedHeight: 0, folds: true))
            }
        }
        items = next
        keepReaderAnchor(among: next)
        model.setItems(layoutItems)
        for id in returned {
            animateHeight(of: id, from: model.displayHeight(of: id), to: model.targetHeight(of: id))
        }
        for (id, departure) in departing where !departure.isCollapsing {
            beginCollapse(id, topInset: departure.piece.paysInsetOutside ? departure.piece.topInset : 0)
        }
        for id in Array(hosts.keys) where next[id] == nil { free(id, force: true) }
        consumedArrivals = consumedArrivals.intersection(next.keys)

        var before: [String: ChatPiece] = [:]
        for piece in previous { before[piece.id] = piece }
        return Set(inputs.pieces.filter { self.hosts[$0.id] != nil && before[$0.id] != $0 }.map(\.id))
    }

    /// Moves the reader's anchor off a piece that is leaving, onto the
    /// nearest one above it that stays, at the same place on screen.
    /// Otherwise the anchor would resolve against an id the model no longer
    /// has, and the list would jump to the top.
    private func keepReaderAnchor(among next: [String: Item]) {
        guard let anchor = readerAnchor, next[anchor.id] == nil, var index = model.index(of: anchor.id) else { return }
        let offset = model.slotTop(of: anchor.id) + anchor.distance
        while index > 0 {
            index -= 1
            let id = model.id(at: index)
            guard next[id] != nil else { continue }
            readerAnchor = (id: id, distance: offset - model.slotTop(of: id))
            return
        }
        readerAnchor = nil
    }

    /// Rebuilds the named roots from the current inputs. A host keeps its
    /// generation, so the measurement its new content reports still applies.
    private func refreshRoots(_ ids: Set<String>) {
        for id in ids {
            guard let host = hosts[id], let item = items[id] else { continue }
            host.view.rootView = makeRoot(for: item, id: id, state: host.state, generation: host.generation)
            applyClipping(for: item, view: host.view, state: host.state)
        }
    }

    /// Estimates depend on the width, which the first layout pass is the
    /// first to know.
    private func reestimateUnmeasured() {
        let width = max(1, model.measurementWidth)
        var estimates: [String: CGFloat] = [:]
        for piece in inputs.pieces where !model.hasMeasurement(piece.id) {
            estimates[piece.id] = ChatPieceEstimate.height(of: piece, width: width)
        }
        model.updateEstimates(estimates)
    }

    // MARK: - Commands

    func scroll(to target: ChatListScrollTarget, animated: Bool) {
        animator.cancelScroll()
        easedOffset = nil
        let clip = scrollView.contentView
        let canAnimate = animated && inputs.animate && model.viewportHeight > 0 && documentView.window != nil
        if canAnimate {
            animator.beginScroll(from: clip.bounds.origin.y, to: target, duration: 0.3)
            easedOffset = clip.bounds.origin.y
        } else {
            land(target)
        }
        documentView.needsLayout = true
    }

    func pin(pieceID: String) {
        pendingPin = pieceID
        model.setAnchor(pieceID, inset: pinTopInset)
        scroll(to: .bottom, animated: true)
    }

    /// Anchors the reader on the piece, so a change around it — a message
    /// collapsing above the row that collapsed it — leaves it where it is
    /// on screen. Only for a piece the reader can see, and never mid-scroll.
    ///
    /// Following the bottom wins unless `overridingFollow`: rows opening
    /// below a reader at the bottom would otherwise push up the very text
    /// they asked to read.
    func hold(pieceID: String, overridingFollow: Bool) {
        guard easedOffset == nil, overridingFollow || !isFollowing else { return }
        let offset = scrollView.contentView.bounds.origin.y
        guard model.visibleIDs(offset: offset).contains(pieceID) else { return }
        isFollowing = false
        followDistance = 0
        readerAnchor = (id: pieceID, distance: offset - model.slotTop(of: pieceID))
    }

    /// Sets the follow state a finished scroll leaves behind.
    private func land(_ target: ChatListScrollTarget) {
        // Whatever follows the pinned prompt is on screen and measured by
        // the time the scroll lands.
        pendingPin = nil
        switch target {
        case .bottom:
            isFollowing = true
            followDistance = 0
            readerAnchor = nil
            setDetached(false)
        case let .item(id):
            isFollowing = false
            // Lands below whatever floats over the list's top edge.
            readerAnchor = (id: id, distance: -inputs.leadingInset)
        }
        Log.chatList.info("landed \(String(describing: target), privacy: .public) at \(Int(self.scrollView.contentView.bounds.origin.y)) follow=\(Int(self.model.followOffset))")
    }

    // MARK: - Scroll events

    @objc private func clipBoundsChanged() {
        guard !isOwnScroll, !isLayingOut else { return }
        let clip = scrollView.contentView
        // A size change is geometry, not intent; the pass it schedules
        // re-resolves the offset from the state the reader already has.
        guard clip.bounds.height == model.viewportHeight, rowWidth(in: clip) == model.measurementWidth,
              model.viewportHeight > 0 else {
            documentView.needsLayout = true
            return
        }
        // Anything else not written by a layout pass is the reader's: a
        // wheel, a momentum tail, a keyboard page.
        animator.cancelScroll()
        easedOffset = nil
        pendingPin = nil
        let offset = clip.bounds.origin.y
        let distance = max(0, model.followOffset - offset)
        isFollowing = distance <= ChatScrollAnchor.bottomTolerance
        followDistance = isFollowing ? distance : 0
        readerAnchor = isFollowing ? nil : model.readerAnchor(offset: offset)
        setDetached(ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: isDetached))
        lastResolvedOffset = resolvedOffset()
        documentView.needsLayout = true
    }

    @objc private func clipFrameChanged() {
        documentView.needsLayout = true
    }

    private func setDetached(_ detached: Bool) {
        guard detached != isDetached else { return }
        isDetached = detached
        let callback = onDetachedChange
        DispatchQueue.main.async { callback(detached) }
    }

    // MARK: - Measurement

    private func report(id: String, height: CGFloat, width: CGFloat, generation: Int) {
        guard let host = hosts[id], host.generation == generation else { return }
        if model.targetHeight(of: id) == height, model.hasMeasurement(id) { return }
        pendingMeasurements.removeAll { $0.id == id }
        pendingMeasurements.append(Measurement(id: id, height: height, width: width, generation: generation))
        documentView.needsLayout = true
    }

    // MARK: - Animation

    /// The rows land in their new column at once; this slides the document's
    /// layer in from where the old column centered them. The render server
    /// interpolates it, so the slide costs the main thread nothing past the
    /// one relayout, and an additive animation per change lets a reversal
    /// mid-slide carry on from where the rows are.
    private func slideFromPreviousColumn(by distance: CGFloat) {
        guard distance != 0, let layer = documentView.layer else { return }
        let animation = CABasicAnimation(keyPath: "bounds.origin.x")
        animation.isAdditive = true
        animation.fromValue = -distance
        animation.toValue = 0
        animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "plume.columnSlide.\(UUID().uuidString)")
    }

    private func tick(at now: TimeInterval) {
        for (key, ease) in animator.eases {
            let value = ease.value(at: now)
            if key == Self.insetEaseKey {
                model.trailingInset = value
            } else if let host = hosts[key] {
                model.setDisplayHeight(value, for: key)
                host.state.containerHeight = value
                if arriving.contains(key) {
                    host.view.alphaValue = ease.progress(at: now)
                } else if departing[key] != nil {
                    host.view.alphaValue = 1 - ease.progress(at: now)
                }
            } else {
                model.setDisplayHeight(value, for: key)
            }
        }
        if let scroll = animator.scroll {
            let progress = scroll.progress(at: now)
            let destination = resolve(scroll.target)
            easedOffset = scroll.from + (destination - scroll.from) * progress
            if scroll.isFinished(at: now) {
                land(scroll.target)
                easedOffset = nil
            }
        }
        var departed = false
        for key in animator.eases.keys where animator.eases[key]!.isFinished(at: now) {
            finishArrival(key)
            if departing.removeValue(forKey: key) != nil { departed = true }
        }
        animator.prune(at: now)
        // Dropped from the items, which frees the host.
        if departed { _ = rebuildItems(previous: inputs.pieces) }
        documentView.needsLayout = true
        documentView.layoutSubtreeIfNeeded()
    }

    /// Runs the frame that ends every animation in flight, so a test need
    /// not race the display link for the main thread.
    func finishAnimations() {
        tick(at: .infinity)
    }

    var realizedIDs: Set<String> { Set(hosts.keys) }

    /// A working indicator that leaves while showing fades and collapses
    /// rather than vanishing, which would jump everything below it. So do
    /// the rows of an agent message collapsing, whose title stays.
    private func startDepartures(from previous: [ChatPiece], staying next: [String: Item]) {
        guard inputs.animate, model.viewportHeight > 0, documentView.window != nil else { return }
        var survivor: String?
        for (index, piece) in previous.enumerated() {
            if next[piece.id] != nil {
                survivor = piece.id
                continue
            }
            let departs = piece.content.isActivityIndicator
                || piece.agentMessageKey.map { next[$0] != nil } == true
            guard departs, hosts[piece.id] != nil, departing[piece.id] == nil else { continue }
            departing[piece.id] = Departure(piece: piece, after: survivor, order: index)
        }
    }

    private func beginCollapse(_ id: String, topInset: CGFloat) {
        guard let host = hosts[id] else {
            departing[id] = nil
            return
        }
        departing[id]?.isCollapsing = true
        finishArrival(id)
        let from = model.displayHeight(of: id) + topInset
        model.setDisplayHeight(from, for: id)
        host.state.containerHeight = from
        animator.ease(id, from: from, to: 0, duration: 0.2)
    }

    private func finishArrival(_ id: String) {
        guard arriving.remove(id) != nil else { return }
        hosts[id]?.view.alphaValue = 1
    }

    /// The offset the current policy asks for, before clamping.
    private func resolvedOffset() -> CGFloat {
        if let easedOffset { return easedOffset }
        if isFollowing { return model.followOffset - followDistance }
        if let readerAnchor { return model.offset(keeping: readerAnchor.id, distance: readerAnchor.distance) }
        return scrollView.contentView.bounds.origin.y
    }

    private func resolve(_ target: ChatListScrollTarget) -> CGFloat {
        switch target {
        case .bottom: model.followOffset
        case let .item(id): max(0, min(model.slotTop(of: id) - inputs.leadingInset, model.maxOffset))
        }
    }

    private func rowWidth(in clip: NSClipView) -> CGFloat {
        max(0, clip.bounds.width - inputs.sideReserve)
    }

    // MARK: - Layout

    /// One pass: measurements in, the window realized, one offset policy
    /// resolved, the document committed, the offset set, hosts placed.
    func layoutPass() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        let clip = scrollView.contentView
        let width = rowWidth(in: clip)
        let viewport = clip.bounds.height
        let widthChanged = width != model.measurementWidth
        model.measurementWidth = width
        model.viewportHeight = viewport

        applyPendingMeasurements()
        if widthChanged, width > 0 {
            reestimateUnmeasured()
            for (id, host) in hosts where departing[id] == nil {
                guard let item = items[id] else { continue }
                remeasure(id: id, item: item, host: host)
            }
        }

        let actual = clip.bounds.origin.y
        if width > 0, viewport > 0 {
            realizeWindow(around: easedOffset ?? actual)
        }

        let desired = min(max(0, resolvedOffset()), model.maxOffset)
        let writes = easedOffset != nil || desired != lastResolvedOffset
        let offset = writes ? desired : actual

        documentView.setFrameSize(NSSize(width: clip.bounds.width, height: max(model.totalHeight, viewport)))
        if writes {
            lastResolvedOffset = desired
            if actual != desired {
                isOwnScroll = true
                clip.scroll(to: NSPoint(x: 0, y: desired))
                scrollView.reflectScrolledClipView(clip)
                isOwnScroll = false
            }
        }
        if !isFollowing, easedOffset == nil {
            let distance = max(0, model.followOffset - offset)
            setDetached(ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: isDetached))
        }

        // The window was realized around the offset the pass started at. A
        // document that shrank enough to move the offset — a long message
        // collapsing — would otherwise leave rows at the new offset blank
        // until something else asks for a pass; the request below, made from
        // inside layout, does not reliably bring one.
        if width > 0, viewport > 0, model.realizedRange(offset: offset) != lastRealizedRange {
            realizeWindow(around: offset)
            documentView.needsLayout = true
        }

        for (id, host) in hosts {
            guard let frame = model.frame(of: id) else { continue }
            host.view.frame = NSRect(x: 0, y: frame.minY, width: width, height: frame.height)
        }
        publishVisibleIDs(offset: offset)
        logPass(offset: offset, viewport: viewport)
    }

    private var lastLog: TimeInterval = 0
    private var trailingLog: DispatchWorkItem?

    /// One line a second at most, plus the state a burst settled on, so a
    /// run with the screen off still leaves evidence of what the list did.
    private func logPass(offset: CGFloat, viewport: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - lastLog > 1 else {
            trailingLog?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.logPass(offset: self.scrollView.contentView.bounds.origin.y, viewport: viewport)
            }
            trailingLog = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            return
        }
        lastLog = now
        Log.chatList.info(
            "pass items=\(self.model.count) realized=\(self.hosts.count) pool=\(self.pool.count) offset=\(Int(offset)) follow=\(Int(self.model.followOffset)) max=\(Int(self.model.maxOffset)) total=\(Int(self.model.totalHeight)) viewport=\(Int(viewport)) slack=\(Int(self.model.slack)) following=\(self.isFollowing) detached=\(self.isDetached) animating=\(self.animator.isAnimating)"
        )
    }

    private var lastRealizedRange = 0..<0

    private func applyPendingMeasurements() {
        let measurements = pendingMeasurements
        pendingMeasurements.removeAll()
        for m in measurements where departing[m.id] == nil {
            let hadMeasurement = model.hasMeasurement(m.id)
            let before = model.displayHeight(of: m.id)
            guard model.setTargetHeight(m.height, for: m.id, width: m.width, generation: m.generation) else { continue }
            if hadMeasurement {
                animateHeight(of: m.id, from: before, to: m.height)
            } else {
                hosts[m.id]?.state.containerHeight = inputs.animate ? m.height : nil
            }
            notePinMeasurement(m.id)
        }
    }

    private func animateHeight(of id: String, from: CGFloat, to: CGFloat) {
        guard from != to else { return }
        if inputs.animate, model.viewportHeight > 0, documentView.window != nil {
            let live: Bool = if case let .piece(piece)? = items[id] { piece.isLive } else { false }
            animator.ease(id, from: from, to: to, duration: live ? 0.12 : 0.2)
        } else {
            model.setDisplayHeight(to, for: id)
            hosts[id]?.state.containerHeight = inputs.animate ? to : nil
        }
    }

    /// Re-pins while the prompt and what follows it are still measuring for
    /// the first time, so only measurements can exhaust the slack, never an
    /// estimate. `land` ends the calibration.
    private func notePinMeasurement(_ id: String) {
        guard let pendingPin, let anchorIndex = model.index(of: pendingPin), let index = model.index(of: id),
              index >= anchorIndex else { return }
        model.setAnchor(pendingPin, inset: pinTopInset)
    }

    /// Realizes inside the window and frees only well outside it, so an item
    /// at the edge of a scroll is not built and torn down on every frame.
    private func realizeWindow(around offset: CGFloat) {
        let range = model.realizedRange(offset: offset)
        lastRealizedRange = range
        let kept = Set(model.realizedRange(offset: offset, overscan: model.overscan * 3).map { model.id(at: $0) })
        // Freeing a departure cancels the ease that would retire it, and it
        // would come back as a working indicator that never leaves.
        for id in Array(hosts.keys) where !kept.contains(id) && departing[id] == nil { free(id) }
        for index in range {
            let id = model.id(at: index)
            guard hosts[id] == nil, let item = items[id] else { continue }
            realize(id: id, item: item)
        }
    }

    private func realize(id: String, item: Item) {
        let state = ChatListItemState()
        let generation = model.realize(id)
        let view = dequeueHost()
        view.rootView = makeRoot(for: item, id: id, state: state, generation: generation)
        applyClipping(for: item, view: view, state: state)
        let host = Host(view: view, state: state, generation: generation)
        hosts[id] = host
        let hadMeasurement = model.hasMeasurement(id)
        let before = model.displayHeight(of: id)
        let measured = naturalHeight(of: view)
        model.setTargetHeight(measured, for: id, width: model.measurementWidth, generation: generation)
        if !hadMeasurement { notePinMeasurement(id) }

        let arrives = inputs.arrivals.contains(id) && !consumedArrivals.contains(id)
        if arrives { consumedArrivals.insert(id) }
        if arrives, inputs.animate, model.viewportHeight > 0, documentView.window != nil {
            arriving.insert(id)
            model.setDisplayHeight(0, for: id)
            view.alphaValue = 0
            state.containerHeight = 0
            animator.ease(id, from: 0, to: measured, duration: 0.2)
        } else if hadMeasurement, before != measured {
            // Realized again after its state was lost, at a different size.
            animateHeight(of: id, from: before, to: measured)
            state.containerHeight = inputs.animate ? before : nil
        } else {
            state.containerHeight = inputs.animate ? measured : nil
        }
        view.isHidden = false
    }

    private func remeasure(id: String, item: Item, host: Host) {
        // Measured at its natural height: with a container height still
        // applied, `fittingSize` would report the frame, not the content.
        host.state.containerHeight = nil
        host.view.rootView = makeRoot(for: item, id: id, state: host.state, generation: host.generation)
        applyClipping(for: item, view: host.view, state: host.state)
        let measured = naturalHeight(of: host.view)
        model.setTargetHeight(measured, for: id, width: model.measurementWidth, generation: host.generation)
        // A width change re-wraps everything at once; easing every row would
        // only smear the reflow.
        model.setDisplayHeight(measured, for: id)
        animator.cancelEase(id)
        finishArrival(id)
        host.state.containerHeight = inputs.animate ? measured : nil
    }

    /// Returns a host to the pool. An evicted item keeps its host while it
    /// holds the keyboard focus; a deleted one (`force`) gives it up.
    private func free(_ id: String, force: Bool = false) {
        guard let host = hosts[id] else { return }
        if let window = host.view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: host.view) {
            guard force else { return }
            window.makeFirstResponder(nil)
        }
        hosts[id] = nil
        finishArrival(id)
        animator.cancelEase(id)
        // Dropped rather than kept: a pooled root that came back for the
        // same id would keep its `@State`, and it holds its own graph.
        host.view.rootView = AnyView(EmptyView())
        host.view.isHidden = true
        // A departure frees its host faded out; the next piece to dequeue it
        // would draw nothing yet still take clicks and selection.
        host.view.alphaValue = 1
        if pool.count < Self.poolLimit {
            pool.append(host.view)
        } else {
            host.view.removeFromSuperview()
        }
    }

    /// `fittingSize` only answers while intrinsic sizing is on, and leaving
    /// it on has every host's constraints re-evaluated on every pass.
    private func naturalHeight(of view: NSHostingView<AnyView>) -> CGFloat {
        view.sizingOptions = .intrinsicContentSize
        defer { view.sizingOptions = [] }
        return view.fittingSize.height
    }

    /// A washed piece stays clipped even while live, because its wash follows
    /// the eased height and the text would spill past it.
    private func applyClipping(for item: Item, view: NSHostingView<AnyView>, state: ChatListItemState) {
        let overflows = if case let .piece(piece) = item { piece.isLive && piece.wash == .none } else { false }
        state.clipsContent = !overflows
        view.clipsToBounds = !overflows
    }

    private func dequeueHost() -> NSHostingView<AnyView> {
        if let view = pool.popLast() { return view }
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(view)
        return view
    }

    private func makeRoot(for item: Item, id: String, state: ChatListItemState, generation: Int) -> AnyView {
        let width = model.measurementWidth
        let onMeasure: (CGFloat) -> Void = { [weak self] height in
            self?.report(id: id, height: height, width: width, generation: generation)
        }
        let environment = ChatListItemEnvironment(
            chatFontSize: inputs.chatFontSize,
            revealModel: revealModel,
            workStartedAt: inputs.workStartedAt,
            linkDirectory: inputs.linkDirectory,
            redoContext: redoContext
        )
        switch item {
        case .leadingInset:
            let height = inputs.leadingInset
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state in
                Color.clear
                    .frame(height: height)
                    .containerHeight(state, onMeasure: onMeasure)
            }.id(id))
        case let .piece(piece):
            let onOpenPlan = onOpenPlan
            // Through the controller rather than captured, so a mounted row
            // calls whichever closure the list holds now.
            let onToggleAgentMessage: (String) -> Void = { [weak self] key in self?.onToggleAgentMessage(key) }
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state in
                ChatPieceView(
                    piece: piece,
                    containerState: state,
                    onNaturalHeight: onMeasure,
                    onOpenPlan: onOpenPlan,
                    onToggleAgentMessage: onToggleAgentMessage
                )
                .listItemPadding(bleed: true, vertical: false)
            }.id(id))
        case .infoPane:
            let facts = inputs.infoPane
            let onOpen = onOpenSubagent
            let onOpenPlan = onOpenPlan ?? {}
            let onOpenSideChat = onOpenSideChat
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state in
                if let facts {
                    InfoPaneInlineBlock(
                        facts: facts,
                        onOpenSubagent: onOpen,
                        onOpenPlan: onOpenPlan,
                        onOpenSideChat: onOpenSideChat
                    )
                        .listItemPadding(vertical: false)
                        .containerHeight(state, onMeasure: onMeasure)
                }
            }.id(id))
        case .dock:
            let tabID = inputs.tabID ?? UUID()
            let onOpenPlan = onOpenPlan
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state in
                PendingPermissionDock(tabID: tabID, onOpenPlan: onOpenPlan)
                    .listItemPadding(bleed: true)
                    .containerHeight(state, onMeasure: onMeasure)
            }.id(id))
        }
    }

    private func publishVisibleIDs(offset: CGFloat) {
        let visible = Set(model.visibleIDs(offset: offset).filter { items[$0].map(isPiece) ?? false })
        guard visible != publishedVisibleIDs else { return }
        publishedVisibleIDs = visible
        let callback = onVisiblePieceIDs
        DispatchQueue.main.async { callback(visible) }
    }

    private func isPiece(_ item: Item) -> Bool {
        if case .piece = item { return true }
        return false
    }
}

/// The scroll view's document: flipped so y grows downward like the model,
/// and laid out by the controller.
final class ChatListDocumentView: NSView {
    weak var controller: ChatListController?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        controller?.layoutPass()
    }
}

/// The SwiftUI root of one hosted item.
///
/// A fresh root has none of the list's environment, so this puts back what
/// every row reads: the theme, the chat font size, the reveal model and the
/// working clock. It also lifts the lazy stack's height ceilings, which this
/// list has no need of. It reads the item's state itself, so a height ease
/// re-renders only this root.
struct ChatListItemEnvironment {
    var chatFontSize: CGFloat
    var revealModel: ChatRevealModel?
    var workStartedAt: Date?
    /// Resolves relative paths in a clicked link. A hosted root inherits no
    /// environment, so the link handler has to be rebuilt here rather than
    /// reaching the row from the chat's own.
    var linkDirectory: URL?
    /// What a user message's redo and fork buttons act on. Nil where the tab
    /// has no live session to rewind.
    var redoContext: MessageRedoContext?
}

struct ChatListItemRoot<Content: View>: View {
    let state: ChatListItemState
    let width: CGFloat
    let environment: ChatListItemEnvironment
    @ViewBuilder let content: (ChatListItemState) -> Content

    var body: some View {
        content(state)
            .frame(width: width, alignment: .top)
            .environment(\.chatFontSize, environment.chatFontSize)
            .environment(\.chatRevealModel, environment.revealModel)
            .environment(\.workStartedAt, environment.workStartedAt)
            .environment(\.messageRedoContext, environment.redoContext)
            .chatLinkHandling(directory: environment.linkDirectory)
            .plumeTheme(bodySize: environment.chatFontSize)
    }
}
