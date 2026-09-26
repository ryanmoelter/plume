/// How the plan view is showing: expanded over the messages, or not — and
/// when not, whether it leaves a dock bar behind or nothing at all.
///
/// Only the shown/not-shown half is a choice. Which of the two hidden forms a
/// not-shown plan takes follows from `PlanApprovalState`, so a proposal
/// waiting on the user can never be dismissed outright and a settled plan
/// never keeps a dock bar the user cannot get rid of.
nonisolated enum PlanPresentation: Equatable {
    case expanded
    case hidden(HiddenForm)

    /// What a not-shown plan leaves behind.
    enum HiddenForm: Equatable {
        /// A bar above the composer. The only hidden form while a proposal is
        /// live: its approval options exist nowhere else, so closing outright
        /// would leave the request open on the wire with no way back to it.
        case dockBar
        /// Nothing. The plan is reachable again from the composer's controls
        /// row.
        case closed
    }

    static func hidden(for approval: PlanApprovalState) -> PlanPresentation {
        .hidden(approval == .awaitingDecision ? .dockBar : .closed)
    }

    var isExpanded: Bool { self == .expanded }

    var hiddenForm: HiddenForm? {
        guard case .hidden(let form) = self else { return nil }
        return form
    }

    /// Re-derives the hidden form against the plan's current state, so an
    /// answer given while the plan is docked drops the bar, and a fresh
    /// proposal arriving while it is closed brings one back.
    func reconciled(with approval: PlanApprovalState) -> PlanPresentation {
        isExpanded ? self : .hidden(for: approval)
    }
}
