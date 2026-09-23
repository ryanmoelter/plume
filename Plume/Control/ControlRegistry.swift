#if DEBUG
import AppKit

/// One control a `plumeID(_:)` modifier has registered. `frame` is in
/// top-left content-view coordinates (see `WindowGeometry`).
struct ControlEntry {
    let token: UUID
    var id: String
    var label: String?
    var value: String?
    var isEnabled: Bool
    var frame: CGRect
    weak var window: NSWindow?
    var invoke: (() -> Void)?
    var setValue: ((String) -> Void)?
}

/// The controls currently on screen, by the `plumeID` each declared. SwiftUI
/// puts identifiers on no NSView, so this registry is the only place the
/// control server can find a hosted button.
@MainActor
final class ControlRegistry {
    static let shared = ControlRegistry()

    private var entries: [UUID: ControlEntry] = [:]

    var count: Int { entries.count }

    func register(_ entry: ControlEntry) {
        entries[entry.token] = entry
    }

    func update(token: UUID, _ change: (inout ControlEntry) -> Void) {
        guard var entry = entries[token] else { return }
        change(&entry)
        entries[token] = entry
    }

    func remove(token: UUID) {
        entries[token] = nil
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Entries sharing an id are ranked top-to-bottom, then left-to-right,
    /// within their window; `index` is that rank, and stays meaningful after
    /// a `label` filter so a caller can name "the second row titled X".
    func entries(id: String? = nil, label: String? = nil, windowNumber: Int? = nil) -> [(index: Int, entry: ControlEntry)] {
        var byID: [String: [ControlEntry]] = [:]
        for entry in entries.values where id == nil || entry.id == id {
            if let windowNumber, entry.window?.windowNumber != windowNumber { continue }
            byID[entry.id, default: []].append(entry)
        }
        var out: [(index: Int, entry: ControlEntry)] = []
        for (_, group) in byID.sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted(by: Self.visualOrder)
            for (index, entry) in ordered.enumerated() {
                if let label, !(entry.label ?? "").localizedCaseInsensitiveContains(label) { continue }
                out.append((index, entry))
            }
        }
        return out
    }

    func resolve(_ target: ControlTarget) throws -> ControlEntry {
        guard case .control(let id, let index, let label) = target else {
            throw ControlError.unsupported("\(target) is not a registered control")
        }
        let matches = entries(id: id, label: label)
        if let index {
            guard let match = matches.first(where: { $0.index == index }) else {
                throw ControlError.notFound("\(id)#\(index)" + (label.map { " matching \"\($0)\"" } ?? ""))
            }
            return match.entry
        }
        switch matches.count {
        case 0: throw ControlError.notFound(id + (label.map { " matching \"\($0)\"" } ?? ""))
        case 1: return matches[0].entry
        default: throw ControlError.ambiguous(id, count: matches.count)
        }
    }

    private static func visualOrder(_ a: ControlEntry, _ b: ControlEntry) -> Bool {
        let wa = a.window?.windowNumber ?? 0, wb = b.window?.windowNumber ?? 0
        if wa != wb { return wa < wb }
        if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
        return a.frame.minX < b.frame.minX
    }
}
#endif
