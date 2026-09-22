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
        InAppDrag.current = self
        return NSItemProvider(object: payload as NSString)
    }

    /// Reads the item a drop carries. The provider only loads asynchronously,
    /// so `completion` runs later, on the main actor, and only for a Plume item.
    static func load(from info: DropInfo, completion: @escaping @MainActor (SidebarDragItem) -> Void) {
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

/// The item the current in-app drag started with.
///
/// A drop's payload loads only asynchronously, but a destination has to pick
/// its feedback on every pointer move, so it reads this instead. Each drag
/// source overwrites it as its drag starts, and a drop acts on the payload,
/// never on this — a value left over from a cancelled drag can mislead the
/// feedback, never the move.
@MainActor
enum InAppDrag {
    static var current: SidebarDragItem?
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
    @Binding var indicator: SidebarDropIndicator?
    let perform: @MainActor (SidebarDragItem, SidebarDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let placement = placement(at: info) else {
            clearIndicator()
            return DropProposal(operation: .forbidden)
        }
        indicator = SidebarDropIndicator(target: target, placement: placement)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { clearIndicator() }

    func performDrop(info: DropInfo) -> Bool {
        clearIndicator()
        let y = info.location.y
        SidebarDragItem.load(from: info) { [target, height, perform] item in
            guard let placement = SidebarDropRules.placement(of: item, over: target, y: y, height: height) else {
                return
            }
            perform(item, placement)
        }
        return true
    }

    /// A drag with no in-app item recorded reads as a tab, so it can still
    /// land in a task. The payload decides the drop either way.
    private func placement(at info: DropInfo) -> SidebarDropPlacement? {
        let item = InAppDrag.current ?? .tab(UUID())
        return SidebarDropRules.placement(of: item, over: target, y: info.location.y, height: height)
    }

    /// Only this target's own indicator: the next target's `dropUpdated` can
    /// run before this one's `dropExited`.
    private func clearIndicator() {
        if indicator?.target == target { indicator = nil }
    }
}

extension View {
    /// Makes a sidebar row or header draggable as `item` and a drop target
    /// as `target`, drawing the insertion line for a reorder over it.
    func sidebarDragAndDrop(
        _ item: SidebarDragItem,
        target: SidebarDropTarget,
        heights: Binding<[UUID: CGFloat]>,
        indicator: Binding<SidebarDropIndicator?>,
        perform: @escaping @MainActor (SidebarDragItem, SidebarDropPlacement) -> Void
    ) -> some View {
        let id = target.id
        return self
            .onDrag { item.itemProvider() }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.wrappedValue[id] = $0 }
            .overlay {
                if let current = indicator.wrappedValue, current.target == target {
                    SidebarInsertionLine(placement: current.placement)
                }
            }
            .onDrop(of: [.utf8PlainText], delegate: SidebarDropDelegate(
                target: target,
                height: heights.wrappedValue[id] ?? 0,
                indicator: indicator,
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

/// A reorder's landing spot, along the top or bottom edge of the row it is
/// over. Drawn as an overlay so it never changes the row's height.
private struct SidebarInsertionLine: View {
    let placement: SidebarDropPlacement

    var body: some View {
        VStack(spacing: 0) {
            if placement == .before { line }
            Spacer(minLength: 0)
            if placement == .after { line }
        }
        .allowsHitTesting(false)
    }

    private var line: some View {
        Capsule()
            .fill(.tint)
            .frame(height: 2)
            .padding(.horizontal, 4)
    }
}
