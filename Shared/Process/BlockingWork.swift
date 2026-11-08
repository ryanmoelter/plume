import Foundation

/// Where work that blocks a thread runs: a wait on a child process, a pipe
/// read, a deadline that kills one.
///
/// The shared pools are the wrong place for it. `DispatchQueue.global()` and
/// the cooperative pool behind `Task.detached` are sized to the core count, so
/// once every thread in them is parked in a blocking call, the next item waits
/// for one to come free, which on a busy three-core machine can be seconds or
/// never. A deadline queued there fires late, and a kill meant to bound a hang
/// becomes part of it. A dedicated thread, and a private serial queue for
/// timers, always get a thread of their own.
nonisolated enum BlockingWork {
    /// Runs `body` on a new thread.
    static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `body` on a new thread and returns its result, without holding a
    /// cooperative thread while it blocks.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            start { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Serial queues are overcommit, so a deadline scheduled here fires on time
    /// even while the shared pool is saturated.
    static let timers = DispatchQueue(label: "com.ryanmoelter.Plume.process-timers", qos: .userInitiated)
}
