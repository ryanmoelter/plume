import Foundation

/// What to tell the user about closing the lid, given what the Mac will
/// actually do.
///
/// Plume cannot keep a Mac awake through a lid close: macOS exposes no API for
/// it, and the assertions Plume does hold document that lid close overrides
/// them. The honest feature is therefore saying what will happen and what the
/// user can change, never a switch that appears to promise otherwise.
enum LidCloseGuidance: Equatable, Sendable {
    /// Closing the lid sleeps the Mac and there is nothing Plume can do.
    case sleepsOnLidClose
    /// Clamshell mode is active, so work continues with the lid closed.
    case staysAwakeInClamshell
    /// No lid, so nothing to say.
    case notApplicable

    static func resolve(
        clamshell: ClamshellSleepBehavior,
        mode: KeepAwakeMode
    ) -> LidCloseGuidance {
        // Never mode already means the user does not want Plume touching
        // sleep, so lid advice would be noise.
        guard mode != .never else { return .notApplicable }

        return switch clamshell {
        case .sleeps: .sleepsOnLidClose
        case .staysAwake: .staysAwakeInClamshell
        case .noClamshell: .notApplicable
        }
    }

    /// The panel's one-line statement of what the lid does right now.
    var summary: String? {
        switch self {
        case .sleepsOnLidClose:
            "Closing the lid sleeps the Mac and pauses every agent."
        case .staysAwakeInClamshell:
            "The lid can stay closed — this Mac is in clamshell mode."
        case .notApplicable:
            nil
        }
    }

    /// Why Plume cannot fix this itself, for the user who expected a toggle.
    ///
    /// Named for the commute the request came from, because that is the case
    /// where the answer is genuinely "this is not possible".
    var explanation: String? {
        guard self == .sleepsOnLidClose else { return nil }
        return "macOS gives apps no way to override this. A Mac stays awake "
            + "with the lid closed only in clamshell mode, which needs an "
            + "external display and power."
    }

    /// Whether to offer the System Settings shortcut, which only helps when
    /// the lid is what will stop the work.
    var offersSystemSettings: Bool { self == .sleepsOnLidClose }
}
