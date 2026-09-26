import Testing
import Foundation
@testable import Plume

/// Covers when the app reinstalls an outdated sleep helper: only an older or
/// silent helper, at most once per launch, never under a hold, and never for
/// a helper that cannot be reached at all.
struct SleepHelperVersionPolicyTests {
    @Test func anOlderHelperIsReinstalled() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&policy, .build("28")) == .reinstall)
    }

    @Test func anEqualOrNewerHelperIsLeftAlone() {
        var equal = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&equal, .build("29")) == .current)
        #expect(check(&equal, .build("1")) == nil)

        var newer = SleepHelperVersionPolicy(appBuild: "28")
        #expect(check(&newer, .build("29")) == .current)
    }

    @Test func aHelperThatRefusesTheRequestIsReinstalled() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&policy, .refused) == .reinstall)
    }

    @Test func reinstallsAtMostOncePerLaunch() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&policy, .refused) == .reinstall)
        #expect(check(&policy, .refused) == .stillOutdated)
        #expect(check(&policy, .refused) == nil)
    }

    @Test func anUnreachableHelperIsNeverReinstalled() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        for _ in 1..<SleepHelperVersionPolicy.maxUnreachableChecks {
            #expect(check(&policy, .unreachable) == .retryLater)
        }
        #expect(check(&policy, .unreachable) == .giveUp)
        #expect(check(&policy, .refused) == nil)
        #expect(!policy.hasReinstalled)
    }

    @Test func aCheckInFlightBlocksAnother() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        let first = policy.beginCheck()
        let second = policy.beginCheck()
        policy.abandonCheck()
        let afterAbandoning = policy.beginCheck()
        #expect(first)
        #expect(!second)
        #expect(afterAbandoning)
    }

    @Test func aHoldDefersTheReinstallUntilACheckFindsItReleased() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&policy, .build("28"), holdActive: true) == .deferReinstall)
        #expect(check(&policy, .build("28")) == nil)
        policy.resumeDeferred()
        #expect(check(&policy, .build("28"), holdActive: true) == .deferReinstall)
        policy.resumeDeferred()
        #expect(check(&policy, .build("28")) == .reinstall)
        #expect(check(&policy, .build("28")) == .stillOutdated)
    }

    @Test func aManualReinstallCountsAsTheOne() {
        var policy = SleepHelperVersionPolicy(appBuild: "29")
        #expect(check(&policy, .refused, holdActive: true) == .deferReinstall)
        policy.recordManualReinstall()
        #expect(check(&policy, .build("28")) == .stillOutdated)
    }

    /// Nil when the policy declines to start the check.
    private func check(
        _ policy: inout SleepHelperVersionPolicy,
        _ answer: SleepHelperVersionPolicy.Answer,
        holdActive: Bool = false
    ) -> SleepHelperVersionPolicy.Decision? {
        guard policy.beginCheck() else { return nil }
        return policy.record(answer, holdActive: holdActive)
    }

    @Test func buildsCompareNumerically() {
        #expect(SleepHelperVersionPolicy.isBuild("9", olderThan: "10"))
        #expect(SleepHelperVersionPolicy.isBuild("1.2", olderThan: "1.10"))
        #expect(!SleepHelperVersionPolicy.isBuild("1.0", olderThan: "1"))
        #expect(!SleepHelperVersionPolicy.isBuild("", olderThan: "29"))
        #expect(!SleepHelperVersionPolicy.isBuild("abc", olderThan: "29"))
        #expect(!SleepHelperVersionPolicy.isBuild("28", olderThan: ""))
    }

    @Test func readsTheBuildOfTheEnclosingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Plume.app/Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        let plist: NSDictionary = ["CFBundleVersion": "42"]
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/PlumeSleepHelper")
        #expect(appBundleBuild(containingExecutable: executable) == "42")
        #expect(appBundleBuild(containingExecutable: root.appendingPathComponent("nowhere/x")) == nil)
    }
}

/// Runs the version query against real anonymous XPC listeners, so what an old
/// helper does with the unknown selector is observed rather than assumed.
struct SleepHelperVersionQueryTests {
    @Test func aCurrentHelperReportsItsBuild() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: SleepHelperProtocol.self), exported: CurrentHelper())
        let reading = await SleepHelperVersionQuery.ask(timeout: 5, connect: server.connect)
        withExtendedLifetime(server) {}
        #expect(reading == .init(answer: .build("29"), overrideEngaged: false))
    }

    @Test func aHelperWithoutTheMethodReadsAsRefused() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: LegacySleepHelperProtocol.self), exported: LegacyHelper())
        let reading = await SleepHelperVersionQuery.ask(timeout: 5, connect: server.connect)
        withExtendedLifetime(server) {}
        #expect(reading == .init(answer: .refused, overrideEngaged: false))
    }

    @Test func aHelperThatNeverAnswersTheVersionReadsAsRefused() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: SleepHelperProtocol.self), exported: SilentVersionHelper())
        let reading = await SleepHelperVersionQuery.ask(timeout: 0.5, connect: server.connect)
        withExtendedLifetime(server) {}
        #expect(reading == .init(answer: .refused, overrideEngaged: false))
    }

    @Test func reportsAnOverrideHeldByAnyClient() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: LegacySleepHelperProtocol.self), exported: LegacyHelper(engaged: true))
        let reading = await SleepHelperVersionQuery.ask(timeout: 5, connect: server.connect)
        withExtendedLifetime(server) {}
        #expect(reading == .init(answer: .refused, overrideEngaged: true))
    }

    @Test func aHelperThatRejectsConnectionsReadsAsUnreachable() async {
        let server = FakeHelperServer(interface: nil, exported: nil)
        let reading = await SleepHelperVersionQuery.ask(timeout: 5, connect: server.connect)
        withExtendedLifetime(server) {}
        #expect(reading == .init(answer: .unreachable, overrideEngaged: false))
    }
}

/// The selectors every helper through 0.13.0 exported.
@objc private protocol LegacySleepHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void)
    func releaseOverride(sleepIfLidClosed: Bool, reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool) -> Void)
    func heartbeat(reply: @escaping (Bool) -> Void)
}

private class LegacyHelper: NSObject, LegacySleepHelperProtocol {
    private let engaged: Bool

    init(engaged: Bool = false) {
        self.engaged = engaged
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool, String?) -> Void) { reply(disabled, nil) }
    func releaseOverride(sleepIfLidClosed: Bool, reply: @escaping (Bool, String?) -> Void) { reply(false, nil) }
    func currentState(reply: @escaping (Bool) -> Void) { reply(engaged) }
    func heartbeat(reply: @escaping (Bool) -> Void) { reply(false) }
}

private class CurrentHelper: LegacyHelper, SleepHelperProtocol {
    func helperBuild(reply: @escaping (String) -> Void) { reply("29") }
}

private final class SilentVersionHelper: CurrentHelper {
    override func helperBuild(reply: @escaping (String) -> Void) {}
}

private final class FakeHelperServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let interface: NSXPCInterface?
    private let exported: AnyObject?

    /// A nil interface rejects every connection.
    init(interface: NSXPCInterface?, exported: AnyObject?) {
        self.interface = interface
        self.exported = exported
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit { listener.invalidate() }

    var connect: @Sendable () -> NSXPCConnection {
        let endpoint = listener.endpoint
        return {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: SleepHelperProtocol.self)
            return connection
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let interface else { return false }
        connection.exportedInterface = interface
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}
