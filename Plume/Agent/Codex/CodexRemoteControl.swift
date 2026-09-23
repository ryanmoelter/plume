import Foundation
import Observation

/// One Plume host at a time. The weak owner cannot keep a closed session alive.
@MainActor
@Observable
final class CodexRemoteControlLease {
    static let shared = CodexRemoteControlLease()
    private(set) weak var owner: CodexRemoteControl?
    func acquire(_ candidate: CodexRemoteControl) -> Bool {
        guard owner == nil || owner === candidate else { return false }
        owner = candidate
        return true
    }
    func release(_ candidate: CodexRemoteControl) {
        if owner === candidate { owner = nil }
    }
}

/// Remote access belongs to this app-server, not a durable per-thread setting.
/// These APIs deliberately use ephemeral toggles: Plume never changes the
/// user's persisted Codex remote-control preference.
@MainActor @Observable
final class CodexRemoteControl {
    typealias Request = @MainActor (String, JSONValue) async throws -> JSONValue
    enum Status: String { case disabled, connecting, connected, errored }
    enum Operation { case enabling, disabling }
    struct Pairing: Equatable {
        let manualCode: String?
        let pairingCode: String
        let expiresAt: Date
        var isUsable: Bool { expiresAt > Date() }
    }
    struct Client: Equatable, Identifiable {
        let id: String
        let displayName: String
        let deviceModel: String?
        let lastSeenAt: Date?
    }

    private(set) var status: Status = .disabled
    private(set) var operation: Operation?
    private(set) var environmentID: String?
    private(set) var serverName: String?
    private(set) var operationError: String?
    private(set) var pairing: Pairing?
    private(set) var pairingClaimed = false
    private(set) var clients: [Client] = []
    private(set) var isLoadingPairing = false
    private(set) var isLoadingClients = false
    private var generation = 0
    private var statusRevision = 0
    private var pairingRevision = 0
    private var clientsRevision = 0
    private var stopped = false
    private var preservesConnectionError = false
    @ObservationIgnored private var errorCleanup: Task<Void, Never>?
    @ObservationIgnored private let lease: CodexRemoteControlLease
    @ObservationIgnored private let request: Request

    init(lease: CodexRemoteControlLease? = nil, request: @escaping Request) {
        self.lease = lease ?? CodexRemoteControlLease()
        self.request = request
    }

    var isAvailableForRemoteAccess: Bool {
        !stopped && (status == .connected || status == .connecting || operation == .enabling)
    }

    func refresh() async {
        guard !stopped else { return }
        let generation = generation
        let revision = statusRevision
        do {
            let result = try await request("remoteControl/status/read", .null)
            guard isCurrent(generation), statusRevision == revision else { return }
            apply(result)
        } catch {
            guard isCurrent(generation), statusRevision == revision else { return }
            operationError = errorMessage(error)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !stopped else { return }
        if enabled, !lease.acquire(self) {
            operationError = "Another Plume Codex chat is serving Remote Control. Disconnect it first."
            return
        }
        errorCleanup?.cancel()
        errorCleanup = nil
        preservesConnectionError = false
        generation += 1
        let generation = generation
        let revision = statusRevision
        operation = enabled ? .enabling : .disabling
        operationError = nil
        clientsRevision += 1
        isLoadingClients = false
        clearPairing()
        do {
            let result = try await request(enabled ? "remoteControl/enable" : "remoteControl/disable", .object(["ephemeral": .bool(true)]))
            guard isCurrent(generation) else { return }
            operation = nil
            // Notifications received while awaiting the reply are newer than
            // its snapshot. In particular, a late enable must not undo off.
            if statusRevision == revision { apply(result) }
        } catch {
            guard isCurrent(generation) else { return }
            operation = nil
            operationError = errorMessage(error)
            if enabled, status != .connected, status != .connecting { lease.release(self) }
        }
    }

    func receive(_ payload: JSONValue) {
        guard !stopped else { return }
        apply(payload)
    }

    private func apply(_ payload: JSONValue) {
        guard let raw = payload["status"]?.stringValue, let status = Status(rawValue: raw) else { return }
        statusRevision += 1
        if (status == .connected || status == .connecting), !lease.acquire(self) {
            self.status = .errored
            operationError = "Another Plume Codex chat is serving Remote Control. Disconnect it first."
            clearPairing()
            cleanUpFailedConnection()
            return
        }
        self.status = status == .disabled && preservesConnectionError ? .errored : status
        if status == .disabled, operation != .enabling { lease.release(self) }
        let newEnvironment = payload["environmentId"]?.stringValue
        if newEnvironment != environmentID || status == .disabled || status == .errored {
            clearPairing()
            clientsRevision += 1
            clients = []
            isLoadingClients = false
        }
        environmentID = newEnvironment
        serverName = payload["serverName"]?.stringValue
        if status == .errored { cleanUpFailedConnection() }
    }

    /// An errored host otherwise keeps retrying, potentially colliding with
    /// another Codex server. Shut down only this ephemeral host, retaining the
    /// failure in the UI rather than presenting an unexplained Off state.
    private func cleanUpFailedConnection() {
        guard !preservesConnectionError else { return }
        preservesConnectionError = true
        operationError = operationError ?? "Codex Remote Control could not connect. Another Codex server may already be using this installation."
        generation += 1
        let generation = generation
        operation = .disabling
        errorCleanup = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await request("remoteControl/disable", .object(["ephemeral": .bool(true)]))
                guard isCurrent(generation), !Task.isCancelled else { return }
                operation = nil
                if result["status"]?.stringValue == "disabled" {
                    lease.release(self)
                    environmentID = nil
                }
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { return }
                operation = nil
                operationError = "Remote Control failed, and stopping its retries failed: \(errorMessage(error))"
            }
            errorCleanup = nil
        }
    }

    func startPairing() async {
        guard !stopped, status == .connected, operation == nil else { return }
        clearPairing()
        let generation = generation
        let revision = pairingRevision
        let environment = environmentID
        isLoadingPairing = true
        operationError = nil
        do {
            let result = try await request("remoteControl/pairing/start", .object(["manualCode": .bool(true)]))
            guard isCurrent(generation), revision == pairingRevision, environment == environmentID else { return }
            isLoadingPairing = false
            guard let code = result["pairingCode"]?.stringValue,
                  let expiry = result["expiresAt"]?.doubleValue,
                  result["environmentId"]?.stringValue == environmentID else {
                operationError = "Codex returned an incomplete pairing code."
                return
            }
            pairing = Pairing(manualCode: result["manualPairingCode"]?.stringValue, pairingCode: code, expiresAt: Self.timestamp(expiry))
        } catch {
            guard isCurrent(generation), revision == pairingRevision else { return }
            isLoadingPairing = false
            operationError = errorMessage(error)
        }
    }

    func refreshPairingStatus() async {
        guard !stopped, status == .connected, let pairing, pairing.isUsable, !pairingClaimed else { return }
        let generation = generation
        let revision = pairingRevision
        do {
            let result = try await request("remoteControl/pairing/status", .object(["pairingCode": .string(pairing.pairingCode)]))
            guard isCurrent(generation), revision == pairingRevision, pairing.isUsable else { return }
            pairingClaimed = result["claimed"]?.boolValue == true
        } catch {
            guard isCurrent(generation), revision == pairingRevision else { return }
            operationError = errorMessage(error)
        }
    }

    func refreshClients() async {
        guard !stopped, let environmentID, status == .connected else { return }
        clientsRevision += 1
        let revision = clientsRevision
        let generation = generation
        isLoadingClients = true
        do {
            var resultClients: [Client] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params: [String: JSONValue] = ["environmentId": .string(environmentID), "limit": .number(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try await request("remoteControl/clients/list", .object(params))
                guard isCurrent(generation), revision == clientsRevision, self.environmentID == environmentID else { return }
                resultClients += result["data"]?.arrayValue?.compactMap { value in
                    guard let id = value["clientId"]?.stringValue else { return nil }
                    return Client(id: id, displayName: value["displayName"]?.stringValue ?? value["deviceModel"]?.stringValue ?? "Paired device", deviceModel: value["deviceModel"]?.stringValue, lastSeenAt: value["lastSeenAt"]?.doubleValue.map { Self.timestamp($0) })
                } ?? []
                cursor = result["nextCursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw ControllerError.repeatedCursor }
            } while cursor != nil
            var ids = Set<String>()
            clients = resultClients.filter { ids.insert($0.id).inserted }
            isLoadingClients = false
        } catch {
            guard isCurrent(generation), revision == clientsRevision else { return }
            isLoadingClients = false
            operationError = errorMessage(error)
        }
    }

    func revokeClient(_ id: String) async {
        guard !stopped, let environmentID else { return }
        let generation = generation
        do {
            _ = try await request("remoteControl/clients/revoke", .object(["environmentId": .string(environmentID), "clientId": .string(id)]))
            guard isCurrent(generation), self.environmentID == environmentID else { return }
            clientsRevision += 1
            isLoadingClients = false
            clients.removeAll { $0.id == id }
        } catch {
            guard isCurrent(generation) else { return }
            operationError = errorMessage(error)
        }
    }

    func stop() {
        errorCleanup?.cancel()
        errorCleanup = nil
        lease.release(self)
        stopped = true
        generation += 1
        status = .disabled
        operation = nil
        environmentID = nil
        clients = []
        isLoadingClients = false
        clearPairing()
    }

    /// Normalize seconds or milliseconds so an expired millisecond Unix
    /// timestamp cannot look valid
    /// for tens of thousands of years.
    private static func timestamp(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value >= 100_000_000_000 ? value / 1_000 : value)
    }

    private func clearPairing() {
        pairingRevision += 1
        pairing = nil
        pairingClaimed = false
        isLoadingPairing = false
    }
    private func errorMessage(_ error: Error) -> String {
        if let failure = error as? CodexAppServerClient.Failure {
            switch failure {
            case .server(_, let message): return message
            case .notRunning: return "Codex is not running."
            case .exited(_, let message): return message ?? "Codex disconnected."
            }
        }
        return error.localizedDescription
    }
    private func isCurrent(_ generation: Int) -> Bool { !stopped && self.generation == generation }
    private enum ControllerError: Error { case repeatedCursor }
}
