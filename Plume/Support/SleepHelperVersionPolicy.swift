import Foundation

/// Decides when `DaemonLidSleepOverride` reinstalls a helper older than the app.
///
/// An in-place update replaces the bundle but not the running helper, which
/// keeps serving while any client stays connected. So the app asks the helper
/// for its build, and reinstalls one that is older or that cannot answer. A
/// newer or equal helper is left alone, and so is one running from another
/// install's bundle: launchd has one job for every Plume install, and only
/// the install that registered it should replace it. At most one reinstall
/// per launch, never while any client holds the override, and a helper that
/// cannot be reached at all is left to the not-loaded check and the back-off.
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
        /// Outdated, but running from another install's bundle, or from one
        /// that could not be found.
        case notOwnBundle
        /// Still outdated after this launch's reinstall; left as it is.
        case stillOutdated
        case retryLater
        case giveUp
    }

    static let maxUnreachableChecks = 3

    let appBuild: String
    let appBundlePath: String
    private(set) var isChecking = false
    private(set) var isSettled = false
    private(set) var hasReinstalled = false
    private(set) var isReinstallDeferred = false
    private(set) var unreachableChecks = 0

    init(appBuild: String, appBundlePath: String) {
        self.appBuild = appBuild
        self.appBundlePath = appBundlePath
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

    /// `helperBundlePath` is nil when the helper's bundle could not be found.
    mutating func record(_ answer: Answer, helperBundlePath: String?, holdActive: Bool) -> Decision {
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
            guard let helperBundlePath, Self.isSameBundle(helperBundlePath, appBundlePath) else {
                isSettled = true
                return .notOwnBundle
            }
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

    /// Lets the next check run, which decides afresh whether a hold still
    /// stands in the way.
    mutating func resumeDeferred() {
        isReinstallDeferred = false
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

    /// An empty path is never the same bundle, so an unreadable one is never
    /// reinstalled.
    static func isSameBundle(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// `realpath` resolves symlinks, including `/tmp` and `/var` into
    /// `/private`, where Foundation's `resolvingSymlinksInPath` strips
    /// `/private` instead. A path that no longer exists falls back to plain
    /// standardizing.
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
    }
}

/// Asks a helper for its build over connections of its own, so a helper that
/// drops the request never costs the lease connection.
nonisolated enum SleepHelperVersionQuery {
    struct Reading: Equatable, Sendable {
        var answer: SleepHelperVersionPolicy.Answer
        /// Nil when unknown: an unreachable helper, or an old one whose
        /// process could not be found.
        var helperBundlePath: String?
        /// Whether `SleepDisabled` is set, by this app or another install.
        var overrideEngaged: Bool
    }

    /// An old helper drops the connection on the unknown selector, which reads
    /// the same as a crash. So `currentState`, which every helper answers,
    /// comes first to tell unreachable from refused, and a failed
    /// `helperBuild` is asked once more before it counts as refused. An old
    /// helper cannot report its bundle, so `legacyBundlePath` finds it.
    static func ask(
        timeout: TimeInterval,
        connect: @escaping @Sendable () -> NSXPCConnection,
        legacyBundlePath: @Sendable () async -> String?
    ) async -> Reading {
        let state: Bool? = await request(timeout: timeout, connect: connect) { helper, reply in
            helper.currentState { reply($0) }
        }
        guard let state else {
            return Reading(answer: .unreachable, helperBundlePath: nil, overrideEngaged: false)
        }
        for _ in 0..<2 {
            let identity: HelperIdentity? = await request(timeout: timeout, connect: connect) { helper, reply in
                helper.helperBuild { reply(HelperIdentity(build: $0, bundlePath: $1)) }
            }
            if let identity {
                return Reading(
                    answer: .build(identity.build),
                    helperBundlePath: identity.bundlePath.isEmpty ? nil : identity.bundlePath,
                    overrideEngaged: state
                )
            }
        }
        return Reading(answer: .refused, helperBundlePath: await legacyBundlePath(), overrideEngaged: state)
    }

    private struct HelperIdentity: Sendable {
        let build: String
        let bundlePath: String
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

    /// The running helper's executable, from `launchctl print`. An
    /// `SMAppService` job lists only a bundle-relative `program identifier`,
    /// so the absolute path comes from its `pid`; a job that does list an
    /// absolute `program` is taken at its word.
    static func helperExecutable(inLaunchctlPrint output: String) -> LaunchctlJob {
        var job = LaunchctlJob()
        for line in output.split(separator: "\n") {
            // Top-level fields sit one tab in; deeper ones belong to nested blocks.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "program" where value.hasPrefix("/"): job.program = value
            case "pid": job.pid = pid_t(value)
            default: break
            }
        }
        return job
    }

    struct LaunchctlJob: Equatable, Sendable {
        var program: String?
        var pid: pid_t?

        var executable: URL? {
            if let program { return URL(fileURLWithPath: program) }
            return pid.flatMap(executableURL(ofProcess:))
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
