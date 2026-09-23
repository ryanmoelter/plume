import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexRemoteControlTests {
    private func status(_ value: String, environment: String = "environment") -> JSONValue {
        .object(["status": .string(value), "environmentId": .string(environment), "serverName": .string("Plume test"), "installationId": .string("installation")])
    }
    private final class Deferred {
        var calls: [(String, JSONValue)] = []
        var replies: [String: CheckedContinuation<JSONValue, Error>] = [:]
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            calls.append((method, params))
            return try await withCheckedThrowingContinuation { replies[method] = $0 }
        }
        func reply(_ method: String, _ result: JSONValue) { replies.removeValue(forKey: method)?.resume(returning: result) }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Remote operation did not start")
        throw CancellationError()
    }

    @Test func inheritedRemoteStateAcquiresLeaseAndCompetingHostCleansUpItself() async throws {
        let lease = CodexRemoteControlLease()
        let first = CodexRemoteControl(lease: lease) { _, _ in self.status("disabled") }
        first.receive(status("connected"))
        var secondCalls: [String] = []
        let second = CodexRemoteControl(lease: lease) { method, _ in
            secondCalls.append(method)
            return self.status("disabled")
        }
        second.receive(status("connecting"))
        try await waitUntil { secondCalls == ["remoteControl/disable"] && second.operation == nil }
        #expect(first.status == .connected)
        #expect(second.status == .errored)
        #expect(second.operationError?.contains("Another Plume") == true)
    }

    @Test func codexRemoteStateFeedsTheSharedStayAwakeReasonsAndStopsOnClose() throws {
        let manager = AgentSessionManager()
        let tabID = UUID(), taskID = UUID()
        let session = try #require(manager.session(for: tabID, taskID: taskID, provider: .codex) as? CodexSession)
        defer { manager.closeAll() }
        session.remoteControl.receive(status("connecting"))
        #expect(session.isRemotelyControlled)
        let second = try #require(manager.session(for: UUID(), taskID: taskID, provider: .codex) as? CodexSession)
        #expect(second.effectiveRemoteControl === session.remoteControl)
        #expect(!second.isRemotelyControlled)
        #expect(manager.remoteControlledTabs.count == 1)
        let reasons = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID, tabID, .permissionNeeded)],
            remoteControlledTabs: manager.remoteControlledTabs
        )
        #expect(reasons.map(\.kind) == [.remoteControl])
        let disabled = KeepAwakeCoordinator.deriveReasons(
            activeTabs: [(taskID, tabID, .permissionNeeded)],
            remoteControlledTabs: manager.remoteControlledTabs,
            allowsRemoteControl: false
        )
        #expect(disabled.isEmpty)
        manager.closeSession(for: tabID)
        #expect(manager.remoteControlledTabs.isEmpty)
        #expect(!session.isRemotelyControlled)
        #expect(second.effectiveRemoteControl === second.remoteControl)
    }

    @Test func leaseAllowsOnlyOneHostAndAcknowledgedDisableReleasesIt() async {
        let lease = CodexRemoteControlLease()
        var secondEnables = 0
        let first = CodexRemoteControl(lease: lease) { method, _ in
            self.status(method == "remoteControl/enable" ? "connected" : "disabled")
        }
        let second = CodexRemoteControl(lease: lease) { _, _ in
            secondEnables += 1
            return self.status("connected")
        }
        await first.setEnabled(true)
        await second.setEnabled(true)
        #expect(secondEnables == 0)
        #expect(second.operationError?.contains("Another Plume") == true)
        await first.setEnabled(false)
        await second.setEnabled(true)
        #expect(secondEnables == 1)
        second.stop()
        await first.setEnabled(true)
        #expect(first.status == .connected)
    }

    @Test func failedDisableRetainsLeaseButFailedEnableReleasesIt() async {
        struct Failure: Error {}
        let lease = CodexRemoteControlLease()
        var rejectDisable = true
        let first = CodexRemoteControl(lease: lease) { method, _ in
            if method == "remoteControl/disable", rejectDisable { throw Failure() }
            return self.status("connected")
        }
        var secondEnables = 0
        let second = CodexRemoteControl(lease: lease) { _, _ in
            secondEnables += 1
            throw Failure()
        }
        await first.setEnabled(true)
        await first.setEnabled(false)
        #expect(first.status == .connected)
        await second.setEnabled(true)
        #expect(secondEnables == 0)
        first.stop()
        await second.setEnabled(true)
        #expect(secondEnables == 1)
        rejectDisable = false
        let third = CodexRemoteControl(lease: lease) { _, _ in self.status("connected") }
        await third.setEnabled(true)
        #expect(third.status == .connected)
    }

    @Test func erroredConnectionStopsRetriesAndKeepsTheFailureVisible() async throws {
        let deferred = Deferred()
        let lease = CodexRemoteControlLease()
        let controller = CodexRemoteControl(lease: lease, request: deferred.request)
        let enable = Task { await controller.setEnabled(true) }
        try await waitUntil { deferred.replies["remoteControl/enable"] != nil }
        deferred.reply("remoteControl/enable", status("connecting"))
        await enable.value
        controller.receive(status("errored"))
        try await waitUntil { deferred.replies["remoteControl/disable"] != nil }
        #expect(deferred.calls.last?.1 == .object(["ephemeral": .bool(true)]))
        controller.receive(status("disabled"))
        deferred.reply("remoteControl/disable", status("disabled"))
        try await waitUntil { controller.operation == nil }
        #expect(controller.status == .errored)
        #expect(controller.operationError != nil)
        let other = CodexRemoteControl(lease: lease) { _, _ in self.status("connected") }
        await other.setEnabled(true)
        #expect(other.status == .connected)
    }

    @Test func statusReadUsesNullAndToggleNeverPersistsPreferences() async {
        var calls: [(String, JSONValue)] = []
        let controller = CodexRemoteControl { method, params in
            calls.append((method, params))
            return self.status(method == "remoteControl/enable" ? "connected" : "disabled")
        }
        await controller.refresh()
        await controller.setEnabled(true)
        #expect(controller.isAvailableForRemoteAccess)
        await controller.setEnabled(false)
        #expect(!controller.isAvailableForRemoteAccess)
        #expect(calls.map(\.0) == ["remoteControl/status/read", "remoteControl/enable", "remoteControl/disable"])
        #expect(calls[0].1 == .null)
        #expect(calls[1].1 == .object(["ephemeral": .bool(true)]))
        #expect(calls[2].1 == .object(["ephemeral": .bool(true)]))
    }

    @Test func disableKeepsConnectionVisibleUntilAcknowledged() async throws {
        let deferred = Deferred()
        let controller = CodexRemoteControl(request: deferred.request)
        controller.receive(status("connected"))
        let operation = Task { await controller.setEnabled(false) }
        try await waitUntil { deferred.replies["remoteControl/disable"] != nil }
        #expect(controller.status == .connected)
        #expect(controller.operation == .disabling)
        #expect(controller.isAvailableForRemoteAccess)
        deferred.reply("remoteControl/disable", status("disabled"))
        await operation.value
        #expect(controller.status == .disabled)
        #expect(controller.operation == nil)
    }

    @Test func cancellingAnEnableCannotBeUndoneByItsLateReply() async throws {
        let deferred = Deferred()
        let controller = CodexRemoteControl(request: deferred.request)
        let enable = Task { await controller.setEnabled(true) }
        try await waitUntil { deferred.replies["remoteControl/enable"] != nil }
        #expect(controller.isAvailableForRemoteAccess)
        let disable = Task { await controller.setEnabled(false) }
        try await waitUntil { deferred.replies["remoteControl/disable"] != nil }
        deferred.reply("remoteControl/disable", status("disabled"))
        await disable.value
        deferred.reply("remoteControl/enable", status("connected"))
        await enable.value
        #expect(controller.status == .disabled)
        #expect(!controller.isAvailableForRemoteAccess)
    }

    @Test func notificationsWinOverOldStatusSnapshotsAndStoppedReplies() async throws {
        let deferred = Deferred()
        let controller = CodexRemoteControl(request: deferred.request)
        let read = Task { await controller.refresh() }
        try await waitUntil { deferred.replies["remoteControl/status/read"] != nil }
        controller.receive(status("connected"))
        deferred.reply("remoteControl/status/read", status("disabled"))
        await read.value
        #expect(controller.status == .connected)
        let enable = Task { await controller.setEnabled(true) }
        try await waitUntil { deferred.replies["remoteControl/enable"] != nil }
        controller.stop()
        deferred.reply("remoteControl/enable", status("connected"))
        await enable.value
        controller.receive(status("connected"))
        #expect(controller.status == .disabled)
        #expect(!controller.isAvailableForRemoteAccess)
    }

    @Test func pairingFailureDoesNotTurnOffALiveConnection() async {
        struct Failure: Error {}
        let controller = CodexRemoteControl { _, _ in throw Failure() }
        controller.receive(status("connected"))
        await controller.startPairing()
        #expect(controller.status == .connected)
        #expect(controller.operationError != nil)
        #expect(!controller.isLoadingPairing)
        #expect(controller.pairing == nil)
    }

    @Test func pairingUsesManualCodeAndExpiredCodeCannotBePolled() async {
        var methods: [String] = []
        let controller = CodexRemoteControl { method, params in
            methods.append(method)
            #expect(params == .object(["manualCode": .bool(true)]))
            return .object(["environmentId": .string("environment"), "manualPairingCode": .string("123456"), "pairingCode": .string("opaque"), "expiresAt": .number(Date().addingTimeInterval(-1).timeIntervalSince1970)])
        }
        controller.receive(status("connected"))
        await controller.startPairing()
        #expect(controller.pairing?.manualCode == "123456")
        #expect(controller.pairing?.isUsable == false)
        await controller.refreshPairingStatus()
        #expect(methods == ["remoteControl/pairing/start"])
    }

    @Test func pairingExpiryAcceptsUnixMilliseconds() async {
        let expired = Date().addingTimeInterval(-60)
        let controller = CodexRemoteControl { _, _ in
            .object(["environmentId": .string("environment"), "manualPairingCode": .string("123456"), "pairingCode": .string("opaque"), "expiresAt": .number(expired.timeIntervalSince1970 * 1_000)])
        }
        controller.receive(status("connected"))
        await controller.startPairing()
        #expect(controller.pairing?.isUsable == false)
        #expect(abs((controller.pairing?.expiresAt.timeIntervalSince1970 ?? 0) - expired.timeIntervalSince1970) < 0.001)
    }

    @Test func environmentChangeDiscardsPairingInFlight() async throws {
        let deferred = Deferred()
        let controller = CodexRemoteControl(request: deferred.request)
        controller.receive(status("connected"))
        let operation = Task { await controller.startPairing() }
        try await waitUntil { deferred.replies["remoteControl/pairing/start"] != nil }
        controller.receive(status("connected", environment: "other"))
        deferred.reply("remoteControl/pairing/start", .object(["environmentId": .string("environment"), "pairingCode": .string("obsolete"), "expiresAt": .number(Date().addingTimeInterval(300).timeIntervalSince1970)]))
        await operation.value
        #expect(controller.pairing == nil)
        #expect(!controller.isLoadingPairing)
    }

    @Test func clientsPaginateAndRevokeUsesTheEnvironmentScope() async {
        var revokeParams: JSONValue?
        var pages = 0
        let controller = CodexRemoteControl { method, params in
            #expect(params["environmentId"] == .string("environment"))
            if method == "remoteControl/clients/revoke" {
                revokeParams = params
                return .object([:])
            }
            pages += 1
            if params["cursor"] == nil {
                return .object(["data": .array([.object(["clientId": .string("a"), "displayName": .string("Phone")])]), "nextCursor": .string("next")])
            }
            return .object(["data": .array([.object(["clientId": .string("b"), "deviceModel": .string("Tablet")])])])
        }
        controller.receive(status("connected"))
        await controller.refreshClients()
        #expect(pages == 2)
        #expect(controller.clients.map(\.displayName) == ["Phone", "Tablet"])
        await controller.revokeClient("a")
        #expect(revokeParams == .object(["environmentId": .string("environment"), "clientId": .string("a")]))
        #expect(controller.clients.map(\.id) == ["b"])
    }
}
