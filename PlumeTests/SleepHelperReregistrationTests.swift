import Testing
import Foundation
@testable import Plume

/// Covers putting an unloaded or outdated helper back into launchd: a plain
/// register comes first when the job is unloaded, an unregister is waited out
/// before registering again, a refused register is retried with a bounded
/// back-off, and a superseded run stops changing anything.
@MainActor
struct SleepHelperReregistrationTests {
    @Test func aPlainRegisterThatLoadsTheJobIsEnough() async {
        let registrar = FakeRegistrar(loaded: [false, true])
        let outcome = await run(registrar)
        #expect(outcome == .loaded(registerAttempts: 0))
        #expect(registrar.calls == [.register])
    }

    @Test func aPlainRegisterThatLeavesTheJobUnloadedFallsBackToUnregistering() async {
        let registrar = FakeRegistrar(loaded: [false, false, false, false, true])
        let outcome = await run(registrar)
        #expect(outcome == .loaded(registerAttempts: 1))
        #expect(registrar.calls == [.register, .unregister, .register])
    }

    @Test func aLoadedJobSkipsThePlainRegister() async {
        let registrar = FakeRegistrar(loaded: [true, true])
        let outcome = await run(registrar)
        #expect(outcome == .loaded(registerAttempts: 1))
        #expect(registrar.calls == [.unregister, .register])
    }

    @Test func aRefusedRegisterAfterUnregisteringIsRetriedUntilItSucceeds() async {
        let registrar = FakeRegistrar(loaded: [true, true])
        registrar.registerResults = [.denied("EPERM"), .denied("EPERM"), .registered]
        let outcome = await run(registrar)
        #expect(outcome == .loaded(registerAttempts: 3))
        #expect(registrar.calls == [.unregister, .register, .register, .register])
        // The first two retry delays.
        #expect(registrar.waits.suffix(2) == [0.5, 1])
    }

    @Test func everyAttemptFailingEndsBoundedAndFailed() async {
        let registrar = FakeRegistrar(loaded: [false, false, false, false])
        registrar.registerResults = Array(repeating: .denied("EPERM"), count: 20)
        let outcome = await run(registrar)
        #expect(outcome == .failed("EPERM"))
        // The plain register, then one register plus one per retry delay.
        let registers = registrar.calls.filter { $0 == .register }.count
        #expect(registers == 1 + 1 + SleepHelperReregistration.registerRetryDelays.count)
        #expect(Array(registrar.waits.suffix(4)) == SleepHelperReregistration.registerRetryDelays)
    }

    @Test func anUnrelatedRegisterErrorIsNotRetried() async {
        let registrar = FakeRegistrar(loaded: [true])
        registrar.registerResults = [.failed("invalid signature")]
        let outcome = await run(registrar)
        #expect(outcome == .failed("invalid signature"))
        #expect(registrar.calls == [.unregister, .register])
    }

    @Test func theUnregisterIsWaitedOutBeforeRegistering() async {
        let registrar = FakeRegistrar(loaded: [true, true])
        registrar.pollsUntilUnregistered = 3
        _ = await run(registrar)
        #expect(registrar.waits.prefix(3) == [0.25, 0.25, 0.25])
        #expect(registrar.statusAtRegister == [.notRegistered])
    }

    @Test func anUnregisterThatNeverSettlesStillRegistersAfterTheTimeout() async {
        let registrar = FakeRegistrar(loaded: [true, true])
        registrar.pollsUntilUnregistered = .max
        let outcome = await run(registrar)
        #expect(outcome == .loaded(registerAttempts: 1))
        let polls = Int(SleepHelperReregistration.unregisterSettleTimeout / SleepHelperReregistration.unregisterPollInterval)
        #expect(registrar.waits.count == polls)
    }

    @Test func aRegisterThatNeedsApprovalStops() async {
        let registrar = FakeRegistrar(loaded: [true])
        registrar.registerResults = [.denied("EPERM")]
        registrar.statusAfterRegister = .requiresApproval
        let outcome = await run(registrar)
        #expect(outcome == .needsApproval)
        #expect(registrar.calls == [.unregister, .register])
    }

    @Test func aSupersededRunChangesNothingMore() async {
        let registrar = FakeRegistrar(loaded: [true])
        registrar.registerResults = Array(repeating: .denied("EPERM"), count: 5)
        var current = true
        registrar.onRegister = { current = false }
        let outcome = await SleepHelperReregistration.run(registrar, isCurrent: { current }, log: { _ in })
        #expect(outcome == .cancelled)
        #expect(registrar.calls == [.unregister, .register])
    }

    private func run(_ registrar: FakeRegistrar) async -> SleepHelperReregistration.Outcome {
        await SleepHelperReregistration.run(registrar, isCurrent: { true }, log: { _ in })
    }
}

@MainActor
private final class FakeRegistrar: SleepHelperRegistrar {
    enum Call: Equatable { case register, unregister }

    var loaded: [Bool]
    var registerResults: [SleepHelperRegisterResult] = []
    var pollsUntilUnregistered = 0
    var statusAfterRegister: SleepHelperServiceStatus = .enabled
    var onRegister: () -> Void = {}
    private(set) var calls: [Call] = []
    private(set) var waits: [TimeInterval] = []
    private(set) var statusAtRegister: [SleepHelperServiceStatus] = []
    private(set) var status: SleepHelperServiceStatus = .enabled
    private var pollsSinceUnregister = 0
    private var isUnregistering = false

    /// Answers to `isLoaded`, in order; the last one repeats.
    init(loaded: [Bool]) {
        self.loaded = loaded
    }

    func register() -> SleepHelperRegisterResult {
        calls.append(.register)
        statusAtRegister.append(status)
        isUnregistering = false
        let result = registerResults.isEmpty ? .registered : registerResults.removeFirst()
        status = result == .registered ? statusAfterRegister : (statusAfterRegister == .requiresApproval ? .requiresApproval : .notRegistered)
        onRegister()
        return result
    }

    func unregister() async -> String? {
        calls.append(.unregister)
        isUnregistering = true
        pollsSinceUnregister = 0
        if pollsUntilUnregistered == 0 { status = .notRegistered }
        return nil
    }

    func isLoaded() async -> Bool? {
        loaded.count > 1 ? loaded.removeFirst() : loaded.first
    }

    func wait(_ seconds: TimeInterval) async {
        waits.append(seconds)
        if isUnregistering, status != .notRegistered {
            pollsSinceUnregister += 1
            if pollsSinceUnregister >= pollsUntilUnregistered { status = .notRegistered }
        }
    }
}
