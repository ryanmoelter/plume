import Foundation
import os
import Observation

/// One physical headless server owns every Plume chat, so remote clients can
/// attach to those same live threads without competing for their writer lock.
@MainActor
@Observable
final class CodexSharedAppServer {
    static let shared = CodexSharedAppServer()
    private let physical: CodexAppServerClient
    private var endpoints: [ObjectIdentifier: CodexAppServerClient] = [:]
    private var initialization: Task<JSONValue, Error>?
    private var didNotifyInitialized = false
    private var requests: Set<CodexRPC.RequestID> = []
    private var generation = 0
    /// Installed by the model layer. Candidates are emitted only after local
    /// thread creation has claimed its returned identity.
    var adoptRemoteThread: ((JSONValue) async -> Bool)?
    private var threadOwners: [String: ObjectIdentifier] = [:]
    private var pendingLocalThreads = 0
    private var remoteCandidates = Set<String>()
    private var adopting = Set<String>()
    private var threadVersions: [String: UUID] = [:]
    private var ignoredThreads = Set<String>()
    private var releasingThreads = Set<String>()
    private var pendingRemoteRequests: [CodexRPC.RequestID: (String, JSONValue)] = [:]
    private(set) var remoteControl: CodexRemoteControl
    var processIdentifier: pid_t? { physical.processIdentifier }

    init(physical: CodexAppServerClient? = nil) {
        let physical = physical ?? CodexAppServerClient()
        self.physical = physical
        remoteControl = CodexRemoteControl(lease: .shared) { method, params in
            try await physical.send(method, params)
        }
        physical.onNotification = { [weak self] method, params in
            guard let self else { return }
            if method == "remoteControl/status/changed" {
                remoteControl.receive(params)
                return
            }
            if method == "serverRequest/resolved", let value = params["requestId"],
               let id = CodexRPC.RequestID(json: value) {
                requests.remove(id)
                pendingRemoteRequests.removeValue(forKey: id)
            }
            for endpoint in Array(endpoints.values) { endpoint.onNotification?(method, params) }
            if method == "thread/started", let id = params["thread"]?["id"]?.stringValue {
                if !releasingThreads.contains(id), pendingLocalThreads == 0 { ignoredThreads.remove(id) }
                discoverRemoteThread(id)
            } else if method == "thread/status/changed", let id = params["threadId"]?.stringValue {
                discoverRemoteThread(id)
            }
        }
        physical.onServerRequest = { [weak self] id, method, params in
            guard let self else { return }
            requests.insert(id)
            let recipients = Array(endpoints.values)
            if params["threadId"]?.stringValue != nil || params["thread_id"]?.stringValue != nil {
                // Sessions validate unknown child ancestry asynchronously;
                // no speculative unsupported response may deny that child.
                for endpoint in recipients { endpoint.onServerRequest?(id, method, params) }
                if let threadID = params["threadId"]?.stringValue ?? params["thread_id"]?.stringValue,
                   threadOwners[threadID] == nil, requests.contains(id) {
                    pendingRemoteRequests[id] = (method, params)
                    discoverRemoteThread(threadID)
                }
            } else if let endpoint = recipients.first {
                endpoint.onServerRequest?(id, method, params)
            } else {
                requests.remove(id)
                physical.respondUnsupported(to: id, method: method)
            }
        }
        physical.onExit = { [weak self] status, message in
            guard let self else { return }
            let recipients = Array(endpoints.values)
            endpoints.removeAll()
            reset()
            for endpoint in recipients { endpoint.handleExit(status: status, message: message) }
        }
    }

    func attach(_ endpoint: CodexAppServerClient, workingDirectory: String?, environment: [String: String]) throws {
        guard endpoints[ObjectIdentifier(endpoint)] == nil else { return }
        if endpoints.isEmpty { try physical.start(workingDirectory: workingDirectory, environment: environment) }
        endpoints[ObjectIdentifier(endpoint)] = endpoint
    }

    func detach(_ endpoint: CodexAppServerClient) {
        guard endpoints.removeValue(forKey: ObjectIdentifier(endpoint)) != nil else { return }
        threadOwners = threadOwners.filter { $0.value != ObjectIdentifier(endpoint) }
        if endpoints.isEmpty {
            physical.stop()
            reset()
        }
    }

    func releaseThread(threadID: String, turnID: String?) {
        let generation = generation
        let version = UUID()
        threadVersions[threadID] = version
        ignoredThreads.insert(threadID)
        releasingThreads.insert(threadID)
        remoteCandidates.remove(threadID)
        Task { [weak self] in
            guard let self, self.generation == generation, threadVersions[threadID] == version, !endpoints.isEmpty else { return }
            defer {
                if self.generation == generation, threadVersions[threadID] == version {
                    releasingThreads.remove(threadID)
                }
            }
            if let turnID {
                _ = try? await physical.send("turn/interrupt", .object([
                    "threadId": .string(threadID), "turnId": .string(turnID)
                ]))
            }
            guard self.generation == generation, threadVersions[threadID] == version, !endpoints.isEmpty else { return }
            _ = try? await physical.send("thread/unsubscribe", .object(["threadId": .string(threadID)]))
        }
    }

    private func reset() {
        generation += 1
        initialization?.cancel()
        initialization = nil
        didNotifyInitialized = false
        requests.removeAll()
        threadOwners.removeAll()
        pendingLocalThreads = 0
        remoteCandidates.removeAll()
        adopting.removeAll()
        ignoredThreads.removeAll()
        releasingThreads.removeAll()
        threadVersions.removeAll()
        pendingRemoteRequests.removeAll()
        remoteControl.stop()
        remoteControl = CodexRemoteControl(lease: .shared) { [physical] method, params in
            try await physical.send(method, params)
        }
    }

    private func attached(_ endpoint: CodexAppServerClient?) -> Bool {
        guard let endpoint else { return false }
        return endpoints[ObjectIdentifier(endpoint)] === endpoint
    }

    func send(from endpoint: CodexAppServerClient?, method: String, params: JSONValue) async throws -> JSONValue {
        guard attached(endpoint) else { throw CodexAppServerClient.Failure.notRunning }
        let requestGeneration = generation
        if method == "initialize" {
            if let initialization {
                let result = try await initialization.value
                guard attached(endpoint), generation == requestGeneration else { throw CodexAppServerClient.Failure.notRunning }
                return result
            }
            let task = Task { [physical] in try await physical.send(method, params) }
            initialization = task
            let generation = generation
            let result: JSONValue
            do { result = try await task.value }
            catch {
                if self.generation == generation { initialization = nil }
                throw error
            }
            guard attached(endpoint), self.generation == requestGeneration else { throw CodexAppServerClient.Failure.notRunning }
            return result
        }
        let createsThread = method == "thread/start" || method == "thread/resume" || method == "thread/fork"
        if createsThread {
            pendingLocalThreads += 1
            if let id = params["threadId"]?.stringValue {
                threadVersions[id] = UUID()
                releasingThreads.remove(id)
                ignoredThreads.remove(id)
            }
        }
        defer {
            if createsThread, generation == requestGeneration {
                pendingLocalThreads -= 1
                flushRemoteCandidates()
            }
        }
        let result = try await physical.send(method, params)
        guard generation == requestGeneration else { throw CodexAppServerClient.Failure.notRunning }
        if createsThread, let id = result["thread"]?["id"]?.stringValue {
            remoteCandidates.remove(id)
            threadVersions[id] = UUID()
            if let endpoint, attached(endpoint) {
                threadOwners[id] = ObjectIdentifier(endpoint)
            } else {
                ignoredThreads.insert(id)
                releaseThread(threadID: id, turnID: nil)
            }
        }
        guard attached(endpoint) else { throw CodexAppServerClient.Failure.notRunning }
        return result
    }

    private func discoverRemoteThread(_ id: String) {
        guard threadOwners[id] == nil, !ignoredThreads.contains(id) else { return }
        remoteCandidates.insert(id)
        flushRemoteCandidates()
    }

    private func flushRemoteCandidates() {
        guard pendingLocalThreads == 0, let adoptRemoteThread else { return }
        for id in Array(remoteCandidates) where !adopting.contains(id) {
            remoteCandidates.remove(id)
            adopting.insert(id)
            let epoch = generation
            Task { [weak self] in
                guard let self else { return }
                defer { if generation == epoch { adopting.remove(id) } }
                do {
                    let result = try await physical.send("thread/read", .object([
                        "threadId": .string(id), "includeTurns": .bool(false)
                    ]))
                    guard generation == epoch, threadOwners[id] == nil, let thread = result["thread"] else { return }
                    guard CodexTerminalMonitor.isConversationRoot(thread) else {
                        ignoredThreads.insert(id)
                        return
                    }
                    // A local start may have begun while read was in flight.
                    guard pendingLocalThreads == 0 else { remoteCandidates.insert(id); return }
                    guard await adoptRemoteThread(thread), generation == epoch else { return }
                    let replay = pendingRemoteRequests
                    for (requestID, request) in replay {
                        guard requests.contains(requestID) else {
                            pendingRemoteRequests.removeValue(forKey: requestID)
                            continue
                        }
                        // A request can belong to a child whose parent has
                        // only just been attached. Sessions validate ancestry;
                        // keep unknown requests until answered or resolved so
                        // a later parent attachment can still receive them.
                        for endpoint in Array(endpoints.values) {
                            endpoint.onServerRequest?(requestID, request.0, request.1)
                        }
                    }
                } catch {
                    Log.agent.error("Could not attach remotely opened Codex conversation: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func notify(from endpoint: CodexAppServerClient, method: String, params: JSONValue?) {
        guard attached(endpoint) else { return }
        if method == "initialized" {
            guard !didNotifyInitialized else { return }
            didNotifyInitialized = true
        }
        physical.notify(method, params)
    }

    func respond(from endpoint: CodexAppServerClient, id: CodexRPC.RequestID, result: JSONValue) {
        guard attached(endpoint), requests.remove(id) != nil else { return }
        pendingRemoteRequests.removeValue(forKey: id)
        physical.respond(to: id, result: result)
    }

    func respondUnsupported(from endpoint: CodexAppServerClient, id: CodexRPC.RequestID, method: String) {
        guard attached(endpoint), requests.remove(id) != nil else { return }
        pendingRemoteRequests.removeValue(forKey: id)
        physical.respondUnsupported(to: id, method: method)
    }
}
