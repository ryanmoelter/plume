import Foundation

/// How much say the user has given Plume over system sleep.
enum KeepAwakeMode: String, CaseIterable, Identifiable, Sendable {
    /// Hold the Mac awake only while something needs it.
    case auto
    /// Hold it regardless, for stepping away before starting anything.
    case always
    /// Never hold it.
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// One answer to "why is this Mac still awake".
///
/// A tab can supply more than one at a time — working *and* remotely
/// controlled are independent reasons — so these are listed, not counted.
struct KeepAwakeReason: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Carries the status so the panel can say which kind of busy this
        /// is without looking it up again.
        case working(TaskStatus)
        case remoteControl
        /// Something the agent started that outlives its turn — a monitor, a
        /// backgrounded command, a workflow. One per tab however many are
        /// running, since the panel lists reasons rather than counting tasks.
        /// The description is what the call said the task was for, absent
        /// when it named nothing.
        case backgroundTask(BackgroundTaskTracker.Kind, description: String?)
    }

    let taskID: UUID
    let tabID: UUID
    let kind: Kind

    var id: String {
        let discriminator = switch kind {
        case .working: "working"
        case .remoteControl: "remote-control"
        case .backgroundTask: "background-task"
        }
        return "\(tabID.uuidString)-\(discriminator)"
    }
}

/// The `ProcessInfo.thermalState` level at or above which the lid-closed
/// override releases, since a shut lid can't shed heat as well as an open
/// one.
enum ThermalCutoffLevel: String, CaseIterable, Identifiable, Sendable {
    case fair
    case serious
    case critical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    /// Apple describes these levels by effect, never by temperature.
    var detail: String {
        switch self {
        case .fair: "Warm. Fans may spin up; nothing is throttled yet."
        case .serious: "Hot. macOS is already throttling the CPU and GPU."
        case .critical: "Very hot. macOS may shut the Mac down soon."
        }
    }

    /// Whether `state` has reached this level or gone past it. Ordering:
    /// nominal < fair < serious < critical.
    func isReached(by state: ProcessInfo.ThermalState) -> Bool {
        switch (self, state) {
        case (.fair, .fair), (.fair, .serious), (.fair, .critical):
            return true
        case (.serious, .serious), (.serious, .critical):
            return true
        case (.critical, .critical):
            return true
        default:
            return false
        }
    }
}

/// Why the coordinator wants to hold the Mac awake but isn't.
enum KeepAwakeOffReason: Equatable, Sendable {
    /// The system is on battery and "Keep awake on battery" is off, so the
    /// coordinator never asked for an assertion.
    case battery
    /// On battery, allowed, but the charge has dropped to or below the
    /// configured cutoff.
    case batteryLow(Int)
    /// An assertion was requested, but the OS declined it anyway.
    case refused
}
