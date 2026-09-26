import Testing
import Foundation
@testable import Plume

/// Covers when the app reinstalls an outdated sleep helper: only an older or
/// silent helper running from the app's own bundle, at most once per launch,
/// never under a hold, and never for a helper that cannot be reached at all.
struct SleepHelperVersionPolicyTests {
    private static let ownBundle = "/Applications/Plume.app"

    @Test func anOlderHelperIsReinstalled() {
        var policy = makePolicy()
        #expect(check(&policy, .build("28")) == .reinstall)
    }

    @Test func anEqualOrNewerHelperIsLeftAlone() {
        var equal = makePolicy()
        #expect(check(&equal, .build("29")) == .current)
        #expect(check(&equal, .build("1")) == nil)

        var newer = makePolicy(appBuild: "28")
        #expect(check(&newer, .build("29")) == .current)
    }

    @Test func aHelperThatRefusesTheRequestIsReinstalled() {
        var policy = makePolicy()
        #expect(check(&policy, .refused) == .reinstall)
    }

    @Test func anotherInstallsHelperIsNeverReinstalled() {
        var older = makePolicy()
        #expect(check(&older, .build("28"), helperBundle: "/Users/me/DerivedData/Build/Products/Debug/Plume.app") == .notOwnBundle)
        #expect(check(&older, .build("28")) == nil)

        var refused = makePolicy()
        #expect(check(&refused, .refused, helperBundle: "/Applications/Other.app") == .notOwnBundle)
        #expect(!refused.hasReinstalled)
    }

    @Test func aHelperWhoseBundleIsUnknownIsNeverReinstalled() {
        var unknown = makePolicy()
        #expect(check(&unknown, .refused, helperBundle: nil) == .notOwnBundle)

        var empty = makePolicy()
        #expect(check(&empty, .build("28"), helperBundle: "") == .notOwnBundle)
    }

    @Test func anotherInstallsCurrentHelperStillReadsCurrent() {
        var policy = makePolicy()
        #expect(check(&policy, .build("30"), helperBundle: "/Applications/Other.app") == .current)
    }

    @Test func reinstallsAtMostOncePerLaunch() {
        var policy = makePolicy()
        #expect(check(&policy, .refused) == .reinstall)
        #expect(check(&policy, .refused) == .stillOutdated)
        #expect(check(&policy, .refused) == nil)
    }

    @Test func anUnreachableHelperIsNeverReinstalled() {
        var policy = makePolicy()
        for _ in 1..<SleepHelperVersionPolicy.maxUnreachableChecks {
            #expect(check(&policy, .unreachable) == .retryLater)
        }
        #expect(check(&policy, .unreachable) == .giveUp)
        #expect(check(&policy, .refused) == nil)
        #expect(!policy.hasReinstalled)
    }

    @Test func aCheckInFlightBlocksAnother() {
        var policy = makePolicy()
        let first = policy.beginCheck()
        let second = policy.beginCheck()
        policy.abandonCheck()
        let afterAbandoning = policy.beginCheck()
        #expect(first)
        #expect(!second)
        #expect(afterAbandoning)
    }

    @Test func aHoldDefersTheReinstallUntilACheckFindsItReleased() {
        var policy = makePolicy()
        #expect(check(&policy, .build("28"), holdActive: true) == .deferReinstall)
        #expect(check(&policy, .build("28")) == nil)
        policy.resumeDeferred()
        #expect(check(&policy, .build("28"), holdActive: true) == .deferReinstall)
        policy.resumeDeferred()
        #expect(check(&policy, .build("28")) == .reinstall)
        #expect(check(&policy, .build("28")) == .stillOutdated)
    }

    @Test func aManualReinstallCountsAsTheOne() {
        var policy = makePolicy()
        #expect(check(&policy, .refused, holdActive: true) == .deferReinstall)
        policy.recordManualReinstall()
        #expect(check(&policy, .build("28")) == .stillOutdated)
    }

    @Test func buildsCompareNumerically() {
        #expect(SleepHelperVersionPolicy.isBuild("9", olderThan: "10"))
        #expect(SleepHelperVersionPolicy.isBuild("1.2", olderThan: "1.10"))
        #expect(!SleepHelperVersionPolicy.isBuild("1.0", olderThan: "1"))
        #expect(!SleepHelperVersionPolicy.isBuild("", olderThan: "29"))
        #expect(!SleepHelperVersionPolicy.isBuild("abc", olderThan: "29"))
        #expect(!SleepHelperVersionPolicy.isBuild("28", olderThan: ""))
    }

    @Test func bundlePathsCompareAfterNormalizing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Plume.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        #expect(SleepHelperVersionPolicy.isSameBundle(bundle.path, bundle.path + "/"))
        #expect(SleepHelperVersionPolicy.isSameBundle(link.path, bundle.path))
        #expect(SleepHelperVersionPolicy.isSameBundle(bundle.path + "/./", bundle.path))
        #expect(!SleepHelperVersionPolicy.isSameBundle(root.appendingPathComponent("Other.app").path, bundle.path))
        #expect(!SleepHelperVersionPolicy.isSameBundle("", bundle.path))
    }

    /// `/tmp` is a symlink to `/private/tmp`, and a helper's path can come
    /// back in either form.
    @Test func aPrivatePrefixDoesNotMakeADifferentBundle() throws {
        let name = "plume-bundle-\(UUID().uuidString).app"
        let tmp = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(SleepHelperVersionPolicy.isSameBundle("/tmp/\(name)", "/private/tmp/\(name)/"))
    }

    @Test func pathsThatNoLongerExistStillCompare() {
        #expect(SleepHelperVersionPolicy.isSameBundle("/nowhere/Plume.app/", "/nowhere/Plume.app"))
        #expect(SleepHelperVersionPolicy.isSameBundle("/nowhere/x/../Plume.app", "/nowhere/Plume.app"))
        #expect(!SleepHelperVersionPolicy.isSameBundle("/nowhere/Plume.app", "/nowhere/Other.app"))
    }

    @Test func readsTheBuildAndBundleOfTheEnclosingApp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Plume.app/Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        let plist: NSDictionary = ["CFBundleVersion": "42"]
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/PlumeSleepHelper")
        #expect(appBundleBuild(containingExecutable: executable) == "42")
        #expect(SleepHelperVersionPolicy.isSameBundle(
            appBundle(containingExecutable: executable).path, root.appendingPathComponent("Plume.app").path
        ))
        #expect(appBundleBuild(containingExecutable: root.appendingPathComponent("nowhere/x")) == nil)
    }

    private func makePolicy(appBuild: String = "29") -> SleepHelperVersionPolicy {
        SleepHelperVersionPolicy(appBuild: appBuild, appBundlePath: Self.ownBundle)
    }

    /// Nil when the policy declines to start the check.
    private func check(
        _ policy: inout SleepHelperVersionPolicy,
        _ answer: SleepHelperVersionPolicy.Answer,
        helperBundle: String? = ownBundle,
        holdActive: Bool = false
    ) -> SleepHelperVersionPolicy.Decision? {
        guard policy.beginCheck() else { return nil }
        return policy.record(answer, helperBundlePath: helperBundle, holdActive: holdActive)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Reads the running helper's executable out of `launchctl print`, for a
/// helper too old to report its own bundle.
struct LaunchctlHelperJobTests {
    /// Trimmed from a real `launchctl print` of an `SMAppService` daemon: the
    /// program is bundle-relative, so only the pid leads to the executable.
    private static let smAppServiceJob = """
    system/com.ryanmoelter.Plume.SleepHelper = {
    \tactive count = 1
    \tpath = (submitted by smd.534)
    \ttype = LaunchDaemon
    \tstate = running

    \tprogram identifier = Contents/MacOS/PlumeSleepHelper (mode: 2)
    \tparent bundle identifier = com.ryanmoelter.Plume
    \tparent bundle version = 28

    \tendpoints = {
    \t\t"com.ryanmoelter.Plume.SleepHelper" = {
    \t\t\tport = 0x1234
    \t\t\tactive = 1
    \t\t}
    \t}
    \tpid = 61748
    \tjob state = running
    }
    """

    @Test func anSMAppServiceJobIsFoundThroughItsPid() {
        let job = SleepHelperVersionQuery.helperExecutable(inLaunchctlPrint: Self.smAppServiceJob)
        #expect(job == .init(program: nil, pid: 61748))
    }

    @Test func anAbsoluteProgramIsTakenAsIs() {
        let output = "system/x = {\n\tprogram = /Applications/Plume.app/Contents/MacOS/PlumeSleepHelper\n\tpid = 7\n}\n"
        let job = SleepHelperVersionQuery.helperExecutable(inLaunchctlPrint: output)
        #expect(job.executable?.path == "/Applications/Plume.app/Contents/MacOS/PlumeSleepHelper")
    }

    @Test func aStoppedJobHasNoExecutable() {
        let output = "system/x = {\n\tprogram identifier = Contents/MacOS/PlumeSleepHelper (mode: 2)\n\tstate = not running\n}\n"
        let job = SleepHelperVersionQuery.helperExecutable(inLaunchctlPrint: output)
        #expect(job.executable == nil)
    }

    @Test func aPidResolvesToItsExecutable() {
        let job = SleepHelperVersionQuery.LaunchctlJob(program: nil, pid: getpid())
        #expect(job.executable?.path == executableURL(ofProcess: getpid())?.path)
        #expect(job.executable != nil)
    }
}

/// Runs the version query against real anonymous XPC listeners, so what an old
/// helper does with the unknown selector is observed rather than assumed.
struct SleepHelperVersionQueryTests {
    private static let legacyBundle = "/Applications/Plume.app"

    @Test func aCurrentHelperReportsItsBuildAndBundle() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: SleepHelperProtocol.self), exported: CurrentHelper())
        let reading = await ask(server)
        #expect(reading == .init(answer: .build("29"), helperBundlePath: "/Users/me/Plume.app", overrideEngaged: false))
    }

    @Test func aHelperWithoutTheMethodReadsAsRefusedWithTheLegacyPath() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: LegacySleepHelperProtocol.self), exported: LegacyHelper())
        let reading = await ask(server)
        #expect(reading == .init(answer: .refused, helperBundlePath: Self.legacyBundle, overrideEngaged: false))
    }

    @Test func aHelperThatNeverAnswersTheVersionReadsAsRefused() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: SleepHelperProtocol.self), exported: SilentVersionHelper())
        let reading = await ask(server, timeout: 0.5)
        #expect(reading == .init(answer: .refused, helperBundlePath: Self.legacyBundle, overrideEngaged: false))
    }

    @Test func reportsAnOverrideHeldByAnyClient() async {
        let server = FakeHelperServer(interface: NSXPCInterface(with: LegacySleepHelperProtocol.self), exported: LegacyHelper(engaged: true))
        let reading = await ask(server)
        #expect(reading == .init(answer: .refused, helperBundlePath: Self.legacyBundle, overrideEngaged: true))
    }

    @Test func aHelperThatRejectsConnectionsReadsAsUnreachable() async {
        let server = FakeHelperServer(interface: nil, exported: nil)
        let reading = await ask(server)
        #expect(reading == .init(answer: .unreachable, helperBundlePath: nil, overrideEngaged: false))
    }

    private func ask(_ server: FakeHelperServer, timeout: TimeInterval = 5) async -> SleepHelperVersionQuery.Reading {
        let reading = await SleepHelperVersionQuery.ask(
            timeout: timeout,
            connect: server.connect,
            legacyBundlePath: { Self.legacyBundle }
        )
        withExtendedLifetime(server) {}
        return reading
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
    func helperBuild(reply: @escaping (String, String) -> Void) { reply("29", "/Users/me/Plume.app") }
}

private final class SilentVersionHelper: CurrentHelper {
    override func helperBuild(reply: @escaping (String, String) -> Void) {}
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
