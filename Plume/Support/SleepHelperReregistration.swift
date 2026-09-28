import Foundation

enum SleepHelperServiceStatus: Equatable, Sendable {
    /// `.notRegistered` or `.notFound`.
    case notRegistered
    case requiresApproval
    case enabled
    case unknown
}

enum SleepHelperRegisterResult: Equatable, Sendable {
    case registered
    /// EPERM or `kSMErrorLaunchDeniedByUser`, which a register right after an
    /// unregister has returned while Background Task Management catches up.
    case denied(String)
    case failed(String)
}

/// `SMAppService` and `launchctl`, as `SleepHelperReregistration` uses them.
@MainActor
protocol SleepHelperRegistrar: AnyObject {
    var status: SleepHelperServiceStatus { get }
    func register() -> SleepHelperRegisterResult
    /// The error's description, or nil on success.
    func unregister() async -> String?
    /// Nil when `launchctl` cannot run.
    func isLoaded() async -> Bool?
    func wait(_ seconds: TimeInterval) async
}

/// Puts an approved helper back into launchd, for the not-loaded recovery,
/// the version reinstall, and the Reinstall button.
///
/// A job launchd has unloaded may come back from a plain `register()`, which
/// keeps the Background Task Management record untouched, so that goes first.
/// Otherwise the helper is unregistered, the status is polled until the
/// unregister shows, and the register is retried with a back-off: a register
/// straight after an unregister has been refused with "Operation not
/// permitted" while the approval still stood.
@MainActor
enum SleepHelperReregistration {
    enum Outcome: Equatable, Sendable {
        /// `registerAttempts` is 0 when the plain register was enough.
        case loaded(registerAttempts: Int)
        case needsApproval
        case failed(String)
        /// The caller's `isCurrent` turned false; nothing more was changed.
        case cancelled
    }

    static let registerRetryDelays: [TimeInterval] = [0.5, 1, 2, 4]
    static let unregisterSettleTimeout: TimeInterval = 5
    static let unregisterPollInterval: TimeInterval = 0.25
    /// Checks for the job after a register, in case launchd lags smd.
    static let loadCheckDelays: [TimeInterval] = [0, 0.25, 0.5]

    static func run(
        _ registrar: some SleepHelperRegistrar,
        isCurrent: () -> Bool,
        log: (String) -> Void
    ) async -> Outcome {
        // A job that is still loaded is an outdated helper still running, which a
        // plain register leaves in place.
        let loadedAtStart = await registrar.isLoaded()
        guard isCurrent() else { return .cancelled }
        if loadedAtStart == false {
            switch registrar.register() {
            case .registered:
                log("Sleep helper: registered without unregistering")
            case .denied(let reason), .failed(let reason):
                log("Sleep helper: register without unregistering failed: \(reason)")
            }
            if registrar.status == .requiresApproval { return .needsApproval }
            let loaded = await waitUntilLoaded(registrar)
            guard isCurrent() else { return .cancelled }
            if loaded == true { return .loaded(registerAttempts: 0) }
            log("Sleep helper: still not loaded; unregistering to register again")
        }

        if let error = await registrar.unregister() {
            log("Sleep helper: unregister failed: \(error)")
        }
        guard isCurrent() else { return .cancelled }

        var waited: TimeInterval = 0
        while registrar.status != .notRegistered, waited < unregisterSettleTimeout {
            await registrar.wait(unregisterPollInterval)
            guard isCurrent() else { return .cancelled }
            waited += unregisterPollInterval
        }
        if registrar.status == .notRegistered {
            log("Sleep helper: unregister settled after \(waited)s")
        } else {
            log("Sleep helper: unregister had not settled after \(waited)s; registering anyway")
        }

        for attempt in 0...registerRetryDelays.count {
            if attempt > 0 {
                await registrar.wait(registerRetryDelays[attempt - 1])
                guard isCurrent() else { return .cancelled }
            }
            switch registrar.register() {
            case .registered:
                if registrar.status == .requiresApproval { return .needsApproval }
                let loaded = await waitUntilLoaded(registrar)
                guard isCurrent() else { return .cancelled }
                // Unknown counts as loaded: the register itself succeeded.
                guard loaded != false else {
                    return .failed("macOS registered the sleep helper, but launchd did not load it.")
                }
                return .loaded(registerAttempts: attempt + 1)
            case .denied(let reason):
                if registrar.status == .requiresApproval { return .needsApproval }
                guard attempt < registerRetryDelays.count else { return .failed(reason) }
                log("Sleep helper: register attempt \(attempt + 1) refused (\(reason)); retrying in \(registerRetryDelays[attempt])s")
            case .failed(let reason):
                if registrar.status == .requiresApproval { return .needsApproval }
                return .failed(reason)
            }
        }
        return .failed("The sleep helper could not be registered.")
    }

    private static func waitUntilLoaded(_ registrar: some SleepHelperRegistrar) async -> Bool? {
        for delay in loadCheckDelays {
            if delay > 0 { await registrar.wait(delay) }
            guard let loaded = await registrar.isLoaded() else { return nil }
            if loaded { return true }
        }
        return false
    }
}
