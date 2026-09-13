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
    private var isDetached = false
    /// The item under the viewport's top edge and how far into it the reader
    /// is, captured whenever the reader scrolls, so heights changing above
    /// them move nothing they can see.
    private var readerAnchor: (id: String, distance: CGFloat)?
    private var easedOffset: CGFloat?
    private var isOwnScroll = false
    private var isLayingOut = false
    /// Set by the reader's scroll, so the pass it schedules leaves the
    /// offset where they put it — including a rubber-band past the end.
    private var leavesOffsetAlone = false
    private var consumedArrivals: Set<String> = []
    private var consumedOpenings: Set<String> = []
    private var arriving: Set<String> = []
    private var publishedVisibleIDs: Set<String> = []
    private var pendingPin: String?

    private static let subagentsID = "plume.trailing.subagents"
    private static let dockID = "plume.trailing.dock"
    private static let insetEaseKey = "plume.trailingInset"
    private static let poolLimit = 40

    private enum Item {
        case piece(ChatPiece)
        case subagents
        case dock
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
        if new.chatFontSize != old.chatFontSize || new.workStartedAt != old.workStartedAt {
            stale.formUnion(hosts.keys)
        }
        if new.subagents != old.subagents { stale.insert(Self.subagentsID) }
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
            next[Self.subagentsID] = .subagents
            next[Self.dockID] = .dock
            layoutItems.append(ChatLayoutItem(id: Self.subagentsID, estimatedHeight: 0))
            layoutItems.append(ChatLayoutItem(id: Self.dockID, estimatedHeight: 0))
        }
        items = next
        model.setItems(layoutItems)
        for id in Array(hosts.keys) where next[id] == nil { free(id) }
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
        for piece in inputs.pieces where !model.hasMeasurement(piece.id) {
            model.updateEstimate(ChatPieceEstimate.height(of: piece, width: width), for: piece.id)
        }
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
        switch target {
        case .bottom:
            isFollowing = true
            readerAnchor = nil
            setDetached(false)
        case let .item(id):
            isFollowing = false
            readerAnchor = (id: id, distance: 0)
        }
    }

    // MARK: - Scroll events

    @objc private func clipBoundsChanged() {
        guard !isOwnScroll, !isLayingOut else { return }
        // Anything not written by a layout pass is the reader's: a wheel, a
        // momentum tail, a keyboard page, or AppKit clamping to a resize.
        animator.cancelScroll()
        easedOffset = nil
        let offset = scrollView.contentView.bounds.origin.y
        let distance = max(0, model.maxOffset - offset)
        isFollowing = distance <= ChatScrollAnchor.bottomTolerance
        readerAnchor = isFollowing ? nil : model.readerAnchor(offset: offset)
        setDetached(ChatScrollAnchor.isDetached(distanceFromBottom: distance, wasDetached: isDetached))
        leavesOffsetAlone = true
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
            arriving.remove(key)
            hosts[key]?.view.alphaValue = 1
        }
        animator.prune(at: now)
        documentView.needsLayout = true
        documentView.layoutSubtreeIfNeeded()
    }

    private func resolve(_ target: ChatListScrollTarget) -> CGFloat {
        switch target {
        case .bottom: model.maxOffset
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

        var offset = easedOffset ?? clip.bounds.origin.y
        if width > 0, viewport > 0 {
            realizeWindow(around: offset)
        }
        if let pendingPin, model.index(of: pendingPin) != nil {
            // Re-pin once the prompt and what follows it have real heights,
            // so the slack cap is set from measurements, not estimates.
            model.setAnchor(pendingPin)
            if hasMeasuredEverything(from: pendingPin) { self.pendingPin = nil }
        }

        if let easedOffset {
            offset = easedOffset
        } else if isFollowing {
            offset = model.maxOffset
        } else if let readerAnchor {
            offset = model.offset(keeping: readerAnchor.id, distance: readerAnchor.distance)
        }
        offset = min(max(0, offset), model.maxOffset)

        documentView.setFrameSize(NSSize(width: width, height: max(model.totalHeight, viewport)))
        let writesOffset = !leavesOffsetAlone
        leavesOffsetAlone = false
        if writesOffset, clip.bounds.origin.y != offset {
            isOwnScroll = true
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(clip)
            isOwnScroll = false
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

    /// One line a second at most, so a run with the screen off still leaves
    /// evidence of what the list did.
    private func logPass(offset: CGFloat, viewport: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - lastLog > 1 else { return }
        lastLog = now
        Log.chatList.info(
            "pass items=\(self.model.count) realized=\(self.hosts.count) pool=\(self.pool.count) offset=\(Int(offset)) max=\(Int(self.model.maxOffset)) total=\(Int(self.model.totalHeight)) viewport=\(Int(viewport)) slack=\(Int(self.model.slack)) following=\(self.isFollowing) detached=\(self.isDetached) animating=\(self.animator.isAnimating)"
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

    private func notePinMeasurement(_ id: String) {
        guard let pendingPin, let anchorIndex = model.index(of: pendingPin), let index = model.index(of: id),
              index >= anchorIndex else { return }
        model.setAnchor(pendingPin)
    }

    private func hasMeasuredEverything(from id: String) -> Bool {
        guard let start = model.index(of: id) else { return true }
        return (start..<model.count).allSatisfy { model.hasMeasurement(model.id(at: $0)) }
    }

    private func realizeWindow(around offset: CGFloat) {
        let range = model.realizedRange(offset: offset)
        lastRealizedRange = range
        let wanted = Set(range.map { model.id(at: $0) })
        for id in Array(hosts.keys) where !wanted.contains(id) { free(id) }
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
        let measured = view.fittingSize.height
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
        host.view.rootView = makeRoot(for: item, id: id, state: host.state, generation: host.generation)
        let measured = host.view.fittingSize.height
        model.setTargetHeight(measured, for: id, width: model.measurementWidth, generation: host.generation)
        // A width change re-wraps everything at once; easing every row would
        // only smear the reflow.
        model.setDisplayHeight(measured, for: id)
        animator.cancelEase(id)
        host.state.containerHeight = inputs.animate ? measured : nil
    }

    private func free(_ id: String) {
        guard let host = hosts[id] else { return }
        if let responder = host.view.window?.firstResponder as? NSView, responder.isDescendant(of: host.view) {
            return
        }
        hosts[id] = nil
        arriving.remove(id)
        animator.cancelEase(id)
        host.view.alphaValue = 1
        host.view.isHidden = true
        if pool.count < Self.poolLimit {
            pool.append(host.view)
        } else {
            host.view.removeFromSuperview()
        }
    }

    private func dequeueHost() -> NSHostingView<AnyView> {
        if let view = pool.popLast() { return view }
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = .intrinsicContentSize
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
            workStartedAt: inputs.workStartedAt
        )
        switch item {
        case let .piece(piece):
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { height, typesFromZero in
                ChatPieceView(
                    piece: piece,
                    typesFromZero: typesFromZero,
                    containerHeight: height,
                    onNaturalHeight: onMeasure
                )
                .listItemPadding(bleed: true, column: .unpadded, vertical: false)
            }.id(id))
        case .subagents:
            let subagents = inputs.subagents
            let tabID = inputs.tabID ?? UUID()
            let onOpen = onOpenSubagent
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { height, _ in
                SubagentListView(subagents: subagents, tabID: tabID, onOpen: onOpen)
                    .listItemPadding(bleed: false, column: .unpadded)
                    .containerHeight(height, onMeasure: onMeasure)
            }.id(id))
        case .dock:
            let tabID = inputs.tabID ?? UUID()
            return AnyView(ChatListItemRoot(state: state, width: width, environment: environment) { height, _ in
                PendingPermissionDock(tabID: tabID)
                    .listItemPadding(bleed: true, column: .unpadded)
                    .containerHeight(height, onMeasure: onMeasure)
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
/// working clock. It reads the item's state itself, so a height ease
/// re-renders only this root.
struct ChatListItemEnvironment {
    var chatFontSize: CGFloat
    var revealClock: RevealClock?
    var workStartedAt: Date?
}

struct ChatListItemRoot<Content: View>: View {
    let state: ChatListItemState
    let width: CGFloat
    let environment: ChatListItemEnvironment
    @ViewBuilder let content: (CGFloat?, Bool) -> Content

    var body: some View {
        content(state.containerHeight, state.typesFromZero)
            .frame(width: width, alignment: .top)
            .environment(\.chatFontSize, environment.chatFontSize)
            .environment(\.revealClock, environment.revealClock)
            .environment(\.workStartedAt, environment.workStartedAt)
            .plumeTheme(bodySize: environment.chatFontSize)
    }
}
