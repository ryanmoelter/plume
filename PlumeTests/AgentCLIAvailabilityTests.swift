import Testing
@testable import Plume

@MainActor
struct AgentCLIAvailabilityTests {
    @Test func repeatedLoadUsesOneProbe() async {
        let probe = ProbeGate(result: [.claudeCode])
        let availability = AgentCLIAvailability { await probe.read() }

        #expect(await availability.load() == [.claudeCode])
        #expect(await availability.load() == [.claudeCode])
        #expect(await probe.callCount == 1)
    }

    @Test func refreshReplacesTheCachedSnapshot() async {
        let probe = ProbeGate(result: [.claudeCode])
        let availability = AgentCLIAvailability { await probe.read() }

        #expect(await availability.load() == [.claudeCode])
        await probe.setResult([.codex])

        #expect(await availability.refresh() == [.codex])
        #expect(await availability.load() == [.codex])
        #expect(await probe.callCount == 2)
    }

    @Test func loadReturnsTheCachedSnapshotWhileRefreshIsPending() async {
        let probe = ProbeGate(result: [.claudeCode])
        let availability = AgentCLIAvailability { await probe.read() }
        #expect(await availability.load() == [.claudeCode])

        await probe.setResult([.codex])
        await probe.blockNextRead()
        let refresh = Task { await availability.refresh() }
        await probe.waitUntilReadStarts()

        #expect(await availability.load() == [.claudeCode])

        await probe.releaseRead()
        #expect(await refresh.value == [.codex])
        #expect(await availability.load() == [.codex])
    }

    @Test func concurrentRefreshesShareOneProbe() async {
        let probe = ProbeGate(result: [.claudeCode])
        let availability = AgentCLIAvailability { await probe.read() }
        await probe.blockNextRead()

        let first = Task { await availability.refresh() }
        await probe.waitUntilReadStarts()
        var second: Task<Set<AgentProviderKind>, Never>!
        await withCheckedContinuation { entered in
            second = Task {
                entered.resume()
                return await availability.refresh()
            }
        }

        #expect(await probe.callCount == 1)
        await probe.releaseRead()
        #expect(await first.value == [.claudeCode])
        #expect(await second.value == [.claudeCode])
        #expect(await probe.callCount == 1)
    }
}

private actor ProbeGate {
    private var result: Set<AgentProviderKind>
    private(set) var callCount = 0
    private var blockNext = false
    private var readStarted = false
    private var readStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var readRelease: CheckedContinuation<Void, Never>?

    init(result: Set<AgentProviderKind>) {
        self.result = result
    }

    func setResult(_ result: Set<AgentProviderKind>) {
        self.result = result
    }

    func blockNextRead() {
        blockNext = true
    }

    func read() async -> Set<AgentProviderKind> {
        callCount += 1
        if blockNext {
            blockNext = false
            readStarted = true
            readStartedWaiters.forEach { $0.resume() }
            readStartedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                readRelease = continuation
            }
        }
        return result
    }

    func waitUntilReadStarts() async {
        if readStarted { return }
        await withCheckedContinuation { continuation in
            readStartedWaiters.append(continuation)
        }
    }

    func releaseRead() {
        readRelease?.resume()
        readRelease = nil
    }
}
