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
    private enum ErrorSource: Equatable {
        case status, toggle, pairing, pairingStatus, clients, revoke(String), connection
    }
    private var errorSource: ErrorSource?
    private(set) var pairing: Pairing?
    private(set) var pairingClaimed = false
    private(set) var clients: [Client] = []
    private(set) var isLoadingPairing = false
    private(set) var isLoadingClients = false
    private(set) var clientsUnavailable = false
    private(set) var revokeUnavailable = false
    private(set) var hasLoadedClients = false
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
            clearError(from: .status)
        } catch {
            guard isCurrent(generation), statusRevision == revision else { return }
            recordError(errorMessage(error), from: .status)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !stopped else { return }
        if enabled, !lease.acquire(self) {
            recordError("Another \(AppIdentity.displayName) Codex chat is serving Remote Control. Disconnect it first.", from: .toggle)
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
        errorSource = nil
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
            // A disabled notification may have arrived while enable was in
            // flight. It deliberately retained ownership until this reply;
            // release now even when that newer notification won the race.
            if status == .disabled { lease.release(self) }
        } catch {
            guard isCurrent(generation) else { return }
            operation = nil
            recordError(errorMessage(error), from: .toggle)
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
            recordError("Another \(AppIdentity.displayName) Codex chat is serving Remote Control. Disconnect it first.", from: .connection)
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
            hasLoadedClients = false
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
        if errorSource != .connection {
            recordError("Codex Remote Control could not connect. Another Codex server may already be using this installation.", from: .connection)
        }
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
                recordError("Remote Control failed, and stopping its retries failed: \(errorMessage(error))", from: .connection)
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
        clearError(from: .pairing)
        clearError(from: .pairingStatus)
        do {
            let result = try await request("remoteControl/pairing/start", .object(["manualCode": .bool(true)]))
            guard isCurrent(generation), revision == pairingRevision, environment == environmentID else { return }
            isLoadingPairing = false
            guard let code = result["pairingCode"]?.stringValue,
                  let expiry = result["expiresAt"]?.doubleValue,
                  result["environmentId"]?.stringValue == environmentID else {
                recordError("Codex returned an incomplete pairing code.", from: .pairing)
                return
            }
            pairing = Pairing(manualCode: result["manualPairingCode"]?.stringValue, pairingCode: code, expiresAt: Self.timestamp(expiry))
        } catch {
            guard isCurrent(generation), revision == pairingRevision else { return }
            isLoadingPairing = false
            recordError(errorMessage(error), from: .pairing)
        }
    }

    func refreshPairingStatus() async {
        guard !stopped, status == .connected, let pairing, pairing.isUsable, !pairingClaimed else { return }
        let generation = generation
        let revision = pairingRevision
        do {
            let result = try await request("remoteControl/pairing/status", .object(["pairingCode": .string(pairing.pairingCode)]))
            guard isCurrent(generation), revision == pairingRevision, pairing.isUsable else { return }
            clearError(from: .pairingStatus)
            pairingClaimed = result["claimed"]?.boolValue == true
        } catch {
            guard isCurrent(generation), revision == pairingRevision else { return }
            recordError(errorMessage(error), from: .pairingStatus)
        }
    }

    func refreshClients() async {
        guard !stopped, !clientsUnavailable, let environmentID, status == .connected else { return }
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
                let result = try await request("remoteControl/client/list", .object(params))
                guard isCurrent(generation), revision == clientsRevision, self.environmentID == environmentID else { return }
                resultClients += result["data"]?.arrayValue?.compactMap { value in
                    guard let id = value["clientId"]?.stringValue else { return nil }
                    return Client(id: id, displayName: value["displayName"]?.stringValue ?? value["deviceModel"]?.stringValue ?? "Paired device", deviceModel: value["deviceModel"]?.stringValue, lastSeenAt: value["lastSeenAt"]?.doubleValue.map { Self.timestamp($0) })
                } ?? []
                cursor = result["nextCursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw ControllerError.repeatedCursor }
            } while cursor != nil
            var ids = Set<String>()
            clearError(from: .clients)
            clients = resultClients.filter { ids.insert($0.id).inserted }
            hasLoadedClients = true
            isLoadingClients = false
        } catch {
            guard isCurrent(generation), revision == clientsRevision else { return }
            isLoadingClients = false
            if unsupported(error, method: "remoteControl/client/list") {
                clientsUnavailable = true
                hasLoadedClients = false
                clients = []
                clearError(from: .clients)
            } else {
                recordError(errorMessage(error), from: .clients)
            }
        }
    }

    func revokeClient(_ id: String) async {
        guard !stopped, !revokeUnavailable, let environmentID else { return }
        let generation = generation
        do {
            _ = try await request("remoteControl/client/revoke", .object(["environmentId": .string(environmentID), "clientId": .string(id)]))
            guard isCurrent(generation), self.environmentID == environmentID else { return }
            clientsRevision += 1
            isLoadingClients = false
            clearError(from: .revoke(id))
            clients.removeAll { $0.id == id }
        } catch {
            guard isCurrent(generation) else { return }
            if unsupported(error, method: "remoteControl/client/revoke") {
                revokeUnavailable = true
                clearError(from: .revoke(id))
            } else {
                recordError(errorMessage(error), from: .revoke(id))
            }
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
    /// Background status polling must not erase a pairing/revoke failure,
    /// nor replace the connection failure retained after retry cleanup.
    private func recordError(_ message: String, from source: ErrorSource) {
        guard !preservesConnectionError || source == .connection else { return }
        operationError = String(message.prefix(400)) + (message.count > 400 ? "…" : "")
        errorSource = source
    }

    private func clearError(from source: ErrorSource) {
        guard !preservesConnectionError, errorSource == source else { return }
        operationError = nil
        errorSource = nil
    }

    private func unsupported(_ error: Error, method: String) -> Bool {
        guard case CodexAppServerClient.Failure.server(let code, let message) = error else { return false }
        return code == -32601 || (message.contains("unknown variant") && message.contains(method))
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
