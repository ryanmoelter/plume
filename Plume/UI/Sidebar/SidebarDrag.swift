import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Something Plume lets the user drag: a tab chip, a sidebar task or a group
/// header, carried as a plain-text payload.
enum SidebarDragItem: Equatable {
    case tab(UUID)
    case task(UUID)
    case group(UUID)

    private static let prefix = "plume-"

    var payload: String {
        switch self {
        case .tab(let id): "\(Self.prefix)tab:\(id.uuidString)"
        case .task(let id): "\(Self.prefix)task:\(id.uuidString)"
        case .group(let id): "\(Self.prefix)group:\(id.uuidString)"
        }
    }

    init?(payload: String) {
        guard payload.hasPrefix(Self.prefix) else { return nil }
        let parts = payload.dropFirst(Self.prefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "tab": self = .tab(id)
        case "task": self = .task(id)
        case "group": self = .group(id)
        default: return nil
        }
    }

    /// Starts a drag of this item and records it as the one in flight.
    @MainActor
    func itemProvider() -> NSItemProvider {
        InAppDrag.shared.begin(self)
        return NSItemProvider(object: payload as NSString)
    }

    /// Hands a drop its item: the in-app drag's before `performDrop` returns,
    /// or else the payload's once it loads, for a drag Plume did not start.
    /// Waiting on the provider for Plume's own drags would hold the drag image
    /// on screen after the drop.
    @MainActor
    static func receive(
        from info: DropInfo,
        drag: InAppDrag = .shared,
        apply: @escaping @MainActor (SidebarDragItem) -> Void
    ) {
        if let item = drag.takeForDrop() {
            apply(item)
        } else {
            load(from: info, completion: apply)
        }
    }

    /// Reads the item a drop carries. The provider only loads asynchronously,
    /// so `completion` runs later, on the main actor, and only for a Plume item.
    private static func load(from info: DropInfo, completion: @escaping @MainActor (SidebarDragItem) -> Void) {
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? NSString else { return }
            let string = String(payload)
            Task { @MainActor in
                if let item = SidebarDragItem(payload: string) { completion(item) }
            }
        }
    }
}

/// The in-app drag in flight, and the drop feedback it draws.
///
/// A drop's payload loads only asynchronously, but a destination has to pick
/// its feedback on every pointer move, so it reads the item here. SwiftUI's
/// `onDrag` reports no end to a drag, so one dropped outside Plume or
/// cancelled ends when the mouse button comes up.
@MainActor
@Observable
final class InAppDrag {
    static let shared = InAppDrag(watchesMouseButton: true)

    private(set) var item: SidebarDragItem?
    private(set) var sidebarIndicator: SidebarDropIndicator?
    private(set) var tabStripGap: TabStripGap?

    @ObservationIgnored private let watchesMouseButton: Bool
    /// How long the item outlives the button coming up. The drop arrives
    /// after the release, and a drop that finds no item takes the payload's
    /// slow path.
    @ObservationIgnored private let releaseGrace: Duration
    @ObservationIgnored private var generation = 0

    init(watchesMouseButton: Bool = false, releaseGrace: Duration = .milliseconds(500)) {
        self.watchesMouseButton = watchesMouseButton
        self.releaseGrace = releaseGrace
    }

    func begin(_ item: SidebarDragItem) {
        generation += 1
        self.item = item
        clearFeedback()
        if watchesMouseButton { watchForRelease(generation) }
    }

    /// Ends the drag as it drops, so a pointer update arriving after the drop
    /// cannot draw feedback again.
    func takeForDrop() -> SidebarDragItem? {
        let taken = item
        end()
        return taken
    }

    func end() {
        if item != nil { item = nil }
        clearFeedback()
    }

    /// Clears the feedback at once, and the item after `releaseGrace` unless
    /// another drag has begun by then.
    @discardableResult
    func buttonReleased() -> Task<Void, Never> {
        clearFeedback()
        let released = generation
        return Task { [releaseGrace] in
            try? await Task.sleep(for: releaseGrace)
            if generation == released { end() }
        }
    }

    /// Ignored with no in-app drag in flight, so a foreign drag draws nothing.
    func showSidebarIndicator(_ indicator: SidebarDropIndicator) {
        guard item != nil, sidebarIndicator != indicator else { return }
        sidebarIndicator = indicator
    }

    /// Clears only `target`'s own indicator: the next target's update can
    /// arrive before this one's exit.
    func clearSidebarIndicator(on target: SidebarDropTarget) {
        if sidebarIndicator?.target == target { sidebarIndicator = nil }
    }

    /// Ignored with no in-app drag in flight, so a foreign drag draws nothing.
    func showTabStripGap(_ gap: TabStripGap) {
        guard item != nil, tabStripGap != gap else { return }
        tabStripGap = gap
    }

    func clearTabStripGap(in taskID: UUID) {
        if tabStripGap?.taskID == taskID { tabStripGap = nil }
    }

    private func clearFeedback() {
        if sidebarIndicator != nil { sidebarIndicator = nil }
        if tabStripGap != nil { tabStripGap = nil }
    }

    private func watchForRelease(_ watched: Int) {
        Task { [weak self] in
            while let self, generation == watched, item != nil {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    buttonReleased()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// The gap a dragged tab would land in, in the strip of task `taskID`.
struct TabStripGap: Equatable {
    let taskID: UUID
    let gap: Int
}

/// Where a sidebar drop lands relative to the row or header under it.
enum SidebarDropPlacement: Equatable {
    case into
    case before
    case after
}

enum SidebarDropTarget: Equatable {
    case task(UUID)
    case group(UUID)
}

/// The drop indicator the sidebar draws.
struct SidebarDropIndicator: Equatable {
    let target: SidebarDropTarget
    let placement: SidebarDropPlacement
}

enum SidebarDropRules {
    /// What dropping `item` at height `y` of a `height`-tall `target` does,
    /// or nil when it does nothing. A tab lands in a task, a task lands in a
    /// group, and a task or group reorders among its own kind by which half of
    /// the target it is over.
    static func placement(
        of item: SidebarDragItem,
        over target: SidebarDropTarget,
        y: CGFloat,
        height: CGFloat
    ) -> SidebarDropPlacement? {
        let half: SidebarDropPlacement = y < height / 2 ? .before : .after
        switch (item, target) {
        case (.tab, .task):
            return .into
        case (.task(let dragged), .task(let over)):
            return dragged == over ? nil : half
        case (.task, .group):
            return .into
        case (.group(let dragged), .group(let over)):
            return dragged == over ? nil : half
        default:
            return nil
        }
    }

    /// The `fromOffsets`/`toOffset` pair for `Array.move` that puts `dragged`
    /// before or after `target` in `ids`, or nil when either is missing.
    static func move(
        _ dragged: UUID,
        _ placement: SidebarDropPlacement,
        _ target: UUID,
        in ids: [UUID]
    ) -> (from: Int, to: Int)? {
        guard let from = ids.firstIndex(of: dragged),
              let targetIndex = ids.firstIndex(of: target),
              placement != .into
        else { return nil }
        return (from, placement == .before ? targetIndex : targetIndex + 1)
    }
}

/// A sidebar row or header's drop handling: which indicator to draw while a
/// drag is over it, and what the drop does.
struct SidebarDropDelegate: DropDelegate {
    let target: SidebarDropTarget
    let height: CGFloat
    let perform: @MainActor (SidebarDragItem, SidebarDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    /// A drag with no in-app item recorded gets no indicator, and its payload
    /// alone decides the drop.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let drag = InAppDrag.shared
        guard let item = drag.item else { return DropProposal(operation: .move) }
        guard let placement = SidebarDropRules.placement(
            of: item, over: target, y: info.location.y, height: height
        ) else {
            drag.clearSidebarIndicator(on: target)
            return DropProposal(operation: .forbidden)
        }
        drag.showSidebarIndicator(SidebarDropIndicator(target: target, placement: placement))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        InAppDrag.shared.clearSidebarIndicator(on: target)
    }

    func performDrop(info: DropInfo) -> Bool {
        let y = info.location.y
        SidebarDragItem.receive(from: info) { [target, height, perform] item in
            guard let placement = SidebarDropRules.placement(of: item, over: target, y: y, height: height) else {
                return
            }
            perform(item, placement)
        }
        return true
    }
}

extension View {
    /// Makes a sidebar row or header draggable as `item` and a drop target
    /// as `target`, marking where a drag over it would land.
    func sidebarDragAndDrop(
        _ item: SidebarDragItem,
        target: SidebarDropTarget,
        heights: Binding<[UUID: CGFloat]>,
        perform: @escaping @MainActor (SidebarDragItem, SidebarDropPlacement) -> Void
    ) -> some View {
        let id = target.id
        return self
            .onDrag { item.itemProvider() }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.wrappedValue[id] = $0 }
            .overlay { SidebarDropMarker(target: target) }
            .onDrop(of: [.utf8PlainText], delegate: SidebarDropDelegate(
                target: target,
                height: heights.wrappedValue[id] ?? 0,
                perform: perform
            ))
    }
}

extension SidebarDropTarget {
    fileprivate var id: UUID {
        switch self {
        case .task(let id), .group(let id): id
        }
    }
}

/// Where a drag over a row or header would land: an outline for a drop into
/// it, or a line along its top or bottom edge for a reorder. An overlay, so
/// it never changes the row's height, and not `.listRowBackground`, which the
/// list does not reliably redraw while the row's content stays the same.
private struct SidebarDropMarker: View {
    let target: SidebarDropTarget

    var body: some View {
        if let indicator = InAppDrag.shared.sidebarIndicator, indicator.target == target {
            Group {
                switch indicator.placement {
                case .into: outline
                case .before, .after: insertionLine(indicator.placement)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.tint, lineWidth: 2)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 6))
            .padding(.horizontal, -4)
    }

    private func insertionLine(_ placement: SidebarDropPlacement) -> some View {
        VStack(spacing: 0) {
            if placement == .before { line }
            Spacer(minLength: 0)
            if placement == .after { line }
        }
    }

    private var line: some View {
        Capsule()
            .fill(.tint)
            .frame(height: 2)
            .padding(.horizontal, 4)
    }
}
