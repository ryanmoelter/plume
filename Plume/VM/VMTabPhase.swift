import Foundation

/// What a `.vm` tab shows for its slot. The tab only views the slot, so a released lease reads as
/// `idle` rather than closing anything.
enum VMTabPhase: Equatable {
    case picker
    case idle(slot: Int)
    case booting(slot: Int, state: VMSlotState)
    case running(slot: Int, hasDisplay: Bool)
    case stopping(slot: Int)
    case failed(slot: Int, message: String, leased: Bool)

    static func of(vmSlot: Int, slot: VMManager.Slot?, hasDisplay: Bool) -> VMTabPhase {
        guard vmSlot != 0, let slot else { return .picker }
        switch slot.state {
        // A claim leases the slot a moment before its boot marks it reserved.
        case .idle: return slot.lease == nil ? .idle(slot: vmSlot) : .booting(slot: vmSlot, state: .reserved)
        case .reserved, .cloning, .starting: return .booting(slot: vmSlot, state: slot.state)
        case .ready: return .running(slot: vmSlot, hasDisplay: hasDisplay)
        case .stopping: return .stopping(slot: vmSlot)
        case .failed: return .failed(slot: vmSlot, message: slot.error ?? "\(slot.key) failed", leased: slot.lease != nil)
        }
    }

    /// The control server's `value` for the tab.
    var label: String {
        switch self {
        case .picker: "picker"
        case .idle: "idle"
        case .booting(_, let state): "booting: \(state.rawValue)"
        case .running(_, let hasDisplay): hasDisplay ? "running" : "running, no display"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}

/// Which VM tab a claim from another tab shows its slot in.
enum VMTabChoice {
    struct Candidate: Equatable {
        var id: UUID
        var vmSlot: Int
        /// Whether `vmSlot` is leased or running, so the tab is showing a live VM.
        var showsLiveSlot: Bool
    }

    /// A tab already on `slot`, then one with no slot, then one whose slot is no longer live. Nil
    /// means open a new tab: a tab showing another live VM is never repointed.
    static func tab(for slot: Int, among candidates: [Candidate]) -> UUID? {
        candidates.first { $0.vmSlot == slot }?.id
            ?? candidates.first { $0.vmSlot == 0 }?.id
            ?? candidates.first { !$0.showsLiveSlot }?.id
    }
}
