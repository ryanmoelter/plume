import Foundation

/// Decides when `DaemonLidSleepOverride` reinstalls a helper older than the app.
///
/// An in-place update replaces the bundle but not the running helper, which
/// keeps serving while any client stays connected. So the app asks the helper
/// for its build, and reinstalls one that is older or that cannot answer. A
/// newer or equal helper is left alone, so a debug build and the installed app
/// never take the job back and forth. At most one reinstall per launch, never
/// under an active hold, and a helper that cannot be reached at all is left to
/// the not-loaded check and the back-off.
nonisolated struct SleepHelperVersionPolicy: Equatable, Sendable {
    enum Answer: Equatable, Sendable {
        case build(String)
        /// Reachable, but it dropped or ignored the version request, as every
        /// helper through 0.13.0 does.
        case refused
        case unreachable
    }

    enum Decision: Equatable, Sendable {
        case current
        case reinstall
        case deferReinstall
        /// Still outdated after this launch's reinstall; left as it is.
        case stillOutdated
        case retryLater
        case giveUp
    }

    static let maxUnreachableChecks = 3

    let appBuild: String
    private(set) var isChecking = false
    private(set) var isSettled = false
    private(set) var hasReinstalled = false
    private(set) var isReinstallDeferred = false
    private(set) var unreachableChecks = 0

    init(appBuild: String) {
        self.appBuild = appBuild
    }

    mutating func beginCheck() -> Bool {
        guard !isChecking, !isSettled, !isReinstallDeferred,
              unreachableChecks < Self.maxUnreachableChecks
        else { return false }
        isChecking = true
        return true
    }

    /// For a check whose result no longer applies.
    mutating func abandonCheck() {
        isChecking = false
    }

    mutating func record(_ answer: Answer, holdActive: Bool) -> Decision {
        isChecking = false
        switch answer {
        case .unreachable:
            unreachableChecks += 1
            guard unreachableChecks >= Self.maxUnreachableChecks else { return .retryLater }
            isSettled = true
            return .giveUp
        case .build(let build) where !Self.isBuild(build, olderThan: appBuild):
            isSettled = true
            return .current
        case .build, .refused:
            if hasReinstalled {
                isSettled = true
                return .stillOutdated
            }
            if holdActive {
                isReinstallDeferred = true
                return .deferReinstall
            }
            hasReinstalled = true
            return .reinstall
        }
    }

    mutating func claimDeferredReinstall(holdActive: Bool) -> Bool {
        guard isReinstallDeferred, !holdActive, !hasReinstalled else { return false }
        isReinstallDeferred = false
        hasReinstalled = true
        return true
    }

    /// A reinstall by hand counts as this launch's one reinstall, and the next
    /// check verifies it.
    mutating func recordManualReinstall() {
        isReinstallDeferred = false
        hasReinstalled = true
        isSettled = false
    }

    /// Compares dotted build numbers numerically. An empty or unparseable
    /// build is never older: a reinstall would not make it readable.
    static func isBuild(_ build: String, olderThan other: String) -> Bool {
        guard let lhs = components(build), let rhs = components(other) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func components(_ build: String) -> [Int]? {
        let parts = build.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}

/// Asks a helper for its build over connections of its own, so a helper that
/// drops the request never costs the lease connection.
nonisolated enum SleepHelperVersionQuery {
    /// An old helper drops the connection on the unknown selector, which reads
    /// the same as a crash. So any failure is followed by `currentState`, which
    /// every helper answers: a reply means the helper is up but cannot report
    /// its build.
    static func ask(
        timeout: TimeInterval,
        connect: @escaping @Sendable () -> NSXPCConnection
    ) async -> SleepHelperVersionPolicy.Answer {
        let build: String? = await request(timeout: timeout, connect: connect) { helper, reply in
            helper.helperBuild { reply($0) }
        }
        if let build { return .build(build) }
        let state: Bool? = await request(timeout: timeout, connect: connect) { helper, reply in
            helper.currentState { reply($0) }
        }
        return state == nil ? .unreachable : .refused
    }

    /// Nil on an XPC error or no reply within `timeout`.
    private static func request<Value: Sendable>(
        timeout: TimeInterval,
        connect: @escaping @Sendable () -> NSXPCConnection,
        send: @escaping @Sendable (any SleepHelperProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value? {
        let connection = connect()
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            let helper = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
            guard let helper = helper as? any SleepHelperProtocol else {
                once.resume(nil)
                return
            }
            send(helper) { once.resume($0) }
        }
    }
}

private nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
