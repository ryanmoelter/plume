import AppKit
import os
import SwiftUI

/// What the custom chat list is asked to draw, as one value so an update that
/// changes nothing can be told from one that does.
struct ChatListInputs: Equatable {
    var pieces: [ChatPiece] = []
    var tabID: UUID?
    var subagents: [SubagentTranscript] = []
    var animate = true
    /// The room the floating composer covers, plus the padding below the
    /// last message.
    var trailingInset: CGFloat = 0
    var chatFontSize: CGFloat = AppSettings.defaultChatFontSize
    var workStartedAt: Date?
    /// Resolves relative paths in a clicked link.
    var linkDirectory: URL?
    var arrivals: Set<String> = []
    var openings: Set<String> = []
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
    var onVisiblePieceIDs: (Set<String>) -> Void = { _ in }
    var onDetachedChange: (Bool) -> Void = { _ in }
    var revealClock: RevealClock?

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
    private var consumedOpenings: Set<String> = []
    private var arriving: Set<String> = []
    private var publishedVisibleIDs: Set<String> = []
    private var pendingPin: String?

    private static let dockID = "plume.trailing.dock"
    private static let subagentsHeaderID = "plume.trailing.subagents.header"
    private static let subagentRowsID = "plume.trailing.subagents.rows"
    private static let insetEaseKey = "plume.trailingInset"
    private static let poolLimit = 40

    private enum Item {
        case piece(ChatPiece)
        case dock
        case subagents(SubagentListView.Part)
    }

    private struct Host {
        let view: NSHostingView<AnyView>
        let state: ChatListItemState
        let generation: Int
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

        if new.pieces != old.pieces || new.tabID != old.tabID {
            stale.formUnion(rebuildItems(previous: old.pieces))
        }
        if new.trailingInset != old.trailingInset {
            if new.animate, model.viewportHeight > 0, documentView.window != nil {
                animator.ease(Self.insetEaseKey, from: model.trailingInset, to: new.trailingInset, duration: 0.2)
            } else {
                model.trailingInset = new.trailingInset
            }
        }
        if new.animate != old.animate {
            if !new.animate {
                for key in animator.eases.keys { animator.cancelEase(key) }
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
        if new.subagents != old.subagents {
            stale.insert(Self.subagentsHeaderID)
            stale.insert(Self.subagentRowsID)
        }
        refreshRoots(stale)
        documentView.needsLayout = true
    }

    /// Returns the ids of realized pieces whose content changed.
    private func rebuildItems(previous: [ChatPiece]) -> Set<String> {
        var next: [String: Item] = [:]
        var layoutItems: [ChatLayoutItem] = []
        layoutItems.reserveCapacity(inputs.pieces.count + 2)
        let width = max(1, model.measurementWidth)
        for piece in inputs.pieces {
            next[piece.id] = .piece(piece)
            layoutItems.append(ChatLayoutItem(
                id: piece.id,
                topInset: piece.paysInsetOutside ? piece.topInset : 0,
                bottomInset: piece.bottomInset,
                estimatedHeight: ChatPieceEstimate.height(of: piece, width: width)
            ))
        }
        if inputs.tabID != nil {
            // The dock needs a click, so it stays above the composer; the
            // subagent rows fold behind it and only their header holds.
            next[Self.dockID] = .dock
            next[Self.subagentsHeaderID] = .subagents(.header)
            next[Self.subagentRowsID] = .subagents(.rows)
            layoutItems.append(ChatLayoutItem(id: Self.dockID, estimatedHeight: 0))
            layoutItems.append(ChatLayoutItem(id: Self.subagentsHeaderID, estimatedHeight: 0))
            layoutItems.append(ChatLayoutItem(id: Self.subagentRowsID, estimatedHeight: 0, folds: true))
        }
        items = next
        model.setItems(layoutItems)
        for id in Array(hosts.keys) where next[id] == nil { free(id, force: true) }
        consumedArrivals = consumedArrivals.intersection(next.keys)
        consumedOpenings = consumedOpenings.intersection(next.keys)

        var before: [String: ChatPiece] = [:]
        for piece in previous { before[piece.id] = piece }
        return Set(inputs.pieces.filter { self.hosts[$0.id] != nil && before[$0.id] != $0 }.map(\.id))
    }

    /// Rebuilds the named roots from the current inputs. A host keeps its
    /// generation, so the measurement its new content reports still applies.
    private func refreshRoots(_ ids: Set<String>) {
        for id in ids {
            guard let host = hosts[id], let item = items[id] else { continue }
            host.view.rootView = makeRoot(for: item, id: id, state: host.state, generation: host.generation)
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
        model.setAnchor(pieceID)
        scroll(to: .bottom, animated: true)
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
            readerAnchor = (id: id, distance: 0)
        }
        Log.chatList.info("landed \(String(describing: target), privacy: .public) at \(Int(self.scrollView.contentView.bounds.origin.y)) follow=\(Int(self.model.followOffset))")
    }

    // MARK: - Scroll events

    @objc private func clipBoundsChanged() {
        guard !isOwnScroll, !isLayingOut else { return }
        let clip = scrollView.contentView
        // A size change is geometry, not intent; the pass it schedules
        // re-resolves the offset from the state the reader already has.
        guard clip.bounds.height == model.viewportHeight, clip.bounds.width == model.measurementWidth,
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
        for key in animator.eases.keys where animator.eases[key]!.isFinished(at: now) {
            finishArrival(key)
        }
        animator.prune(at: now)
        documentView.needsLayout = true
        documentView.layoutSubtreeIfNeeded()
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
        case let .item(id): min(model.slotTop(of: id), model.maxOffset)
        }
    }

    // MARK: - Layout

    /// One pass: measurements in, the window realized, one offset policy
    /// resolved, the document committed, the offset set, hosts placed.
    func layoutPass() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        let clip = scrollView.contentView
        let width = clip.bounds.width
        let viewport = clip.bounds.height
        let widthChanged = width != model.measurementWidth
        model.measurementWidth = width
        model.viewportHeight = viewport

        applyPendingMeasurements()
        if widthChanged, width > 0 {
            reestimateUnmeasured()
            for (id, host) in hosts {
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

        documentView.setFrameSize(NSSize(width: width, height: max(model.totalHeight, viewport)))
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

        for (id, host) in hosts {
            guard let frame = model.frame(of: id) else { continue }
            host.view.frame = NSRect(x: 0, y: frame.minY, width: width, height: frame.height)
        }

        if width > 0, viewport > 0, model.realizedRange(offset: offset) != lastRealizedRange {
            documentView.needsLayout = true
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
        for m in measurements {
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
        model.setAnchor(pendingPin)
    }

    /// Realizes inside the window and frees only well outside it, so an item
    /// at the edge of a scroll is not built and torn down on every frame.
    private func realizeWindow(around offset: CGFloat) {
        let range = model.realizedRange(offset: offset)
        lastRealizedRange = range
        let kept = Set(model.realizedRange(offset: offset, overscan: model.overscan * 3).map { model.id(at: $0) })
        for id in Array(hosts.keys) where !kept.contains(id) { free(id) }
        for index in range {
            let id = model.id(at: index)
            guard hosts[id] == nil, let item = items[id] else { continue }
            realize(id: id, item: item)
        }
    }

    private func realize(id: String, item: Item) {
        let state = ChatListItemState()
        if inputs.openings.contains(id), !consumedOpenings.contains(id) {
            consumedOpenings.insert(id)
            state.typesFromZero = true
        }
        let generation = model.realize(id)
        let view = dequeueHost()
        view.rootView = makeRoot(for: item, id: id, state: state, generation: generation)
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
            revealClock: revealClock,
            workStartedAt: inputs.workStartedAt,
            linkDirectory: inputs.linkDirectory
        )
        switch item {
        case let .piece(piece):
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state, typesFromZero in
                ChatPieceView(
                    piece: piece,
                    typesFromZero: typesFromZero,
                    containerState: state,
                    onNaturalHeight: onMeasure
                )
                .listItemPadding(bleed: true, column: .unpadded, vertical: false)
            }.id(id))
        case let .subagents(part):
            let subagents = inputs.subagents
            let tabID = inputs.tabID ?? UUID()
            let onOpen = onOpenSubagent
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state, _ in
                SubagentListView(subagents: subagents, tabID: tabID, onOpen: onOpen, part: part)
                    .listItemPadding(bleed: false, column: .unpadded, vertical: false)
                    .containerHeight(state, onMeasure: onMeasure)
            }.id(id))
        case .dock:
            let tabID = inputs.tabID ?? UUID()
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { state, _ in
                PendingPermissionDock(tabID: tabID)
                    .listItemPadding(bleed: true, column: .unpadded)
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
/// every row reads: the theme, the chat font size, the reveal clock and the
/// working clock. It also lifts the lazy stack's height ceilings, which this
/// list has no need of. It reads the item's state itself, so a height ease
/// re-renders only this root.
struct ChatListItemEnvironment {
    var chatFontSize: CGFloat
    var revealClock: RevealClock?
    var workStartedAt: Date?
    /// Resolves relative paths in a clicked link. A hosted root inherits no
    /// environment, so the link handler has to be rebuilt here rather than
    /// reaching the row from the chat's own.
    var linkDirectory: URL?
}

struct ChatListItemRoot<Content: View>: View {
    let state: ChatListItemState
    let width: CGFloat
    let environment: ChatListItemEnvironment
    @ViewBuilder let content: (ChatListItemState, Bool) -> Content

    var body: some View {
        content(state, state.typesFromZero)
            .frame(width: width, alignment: .top)
            .environment(\.chatFontSize, environment.chatFontSize)
            .environment(\.revealClock, environment.revealClock)
            .environment(\.workStartedAt, environment.workStartedAt)
            .chatLinkHandling(directory: environment.linkDirectory)
            .plumeTheme(bodySize: environment.chatFontSize)
    }
}
