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
    }

    let taskID: UUID
    let tabID: UUID
    let kind: Kind

    var id: String {
        let discriminator = switch kind {
        case .working: "working"
        case .remoteControl: "remote-control"
        }
        return "\(tabID.uuidString)-\(discriminator)"
    }
}
