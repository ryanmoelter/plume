import Foundation
import os

/// Each terminal has a private server shared by the real Codex TUI and this
/// read-only observer. Only the TUI answers requests or starts/resumes turns.
@MainActor
final class CodexTerminalMonitor {
    static let shared = CodexTerminalMonitor()
    private var sessions: [UUID: Observation] = [:]

    func owns(threadID: String, excludingTabID: UUID) -> Bool {
        sessions.contains { id, observation in
            id != excludingTabID && !observation.stopped &&
                (observation.rootID == threadID || observation.loadedIDs.contains(threadID))
        }
    }

    func start(tabID: UUID, taskID: UUID, directory: String?, resumeThreadID: String? = nil, onThread: @escaping (String) -> Void) throws -> String {
        if let existing = sessions[tabID] { return existing.socketPath }
        let observation = try Observation(tabID: tabID, taskID: taskID, directory: directory, resumeThreadID: resumeThreadID, onThread: onThread)
        sessions[tabID] = observation
        observation.onStop = { [weak self, weak observation] in
            guard let self, sessions[tabID] === observation else { return }
            sessions.removeValue(forKey: tabID)
        }
        return observation.socketPath
    }

    func reparent(tabID: UUID, taskID: UUID) { sessions[tabID]?.taskID = taskID }

    func stop(tabID: UUID) { sessions.removeValue(forKey: tabID)?.stop() }
    func stopAll() {
        for session in Array(sessions.values) { session.stop() }
        sessions.removeAll()
    }

    static func isConversationRoot(_ thread: JSONValue) -> Bool {
        thread["ephemeral"] != .bool(true) && thread["parentThreadId"]?.stringValue == nil && thread["source"]?["subAgent"] == nil
    }

    static func aggregateStatus(_ threads: [JSONValue]) -> TaskStatus {
        let statuses = threads.map { status($0["status"] ?? .null) }
        return statuses.isEmpty ? .awaitingReply : TaskStatus.aggregate(statuses)
    }

    static func status(_ value: JSONValue) -> TaskStatus {
        switch value["type"]?.stringValue {
        case "active":
            let flags = value["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if flags.contains("waitingOnApproval") { return .permissionNeeded }
            if flags.contains("waitingOnUserInput") { return .questionAsked }
            return .working
        case "systemError": return .error
        default: return .awaitingReply
        }
    }

    private final class Observation {
        let socketPath: String
        let tabID: UUID
        var taskID: UUID
        let directory: URL
        var wire = CodexUnixWebSocket()
        var connectionGeneration = 0
        var observerFailed = false
        var reconnectAttempts = 0
        var reconnect: Task<Void, Never>?
        var client: CodexAppServerClient!
        var process: AgentProcess?
        var worker: Task<Void, Never>?
        var reader: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var background: CodexBackgroundTaskTracker?
        var stopped = false
        var onStop: (() -> Void)?
        var lastRead = Date()
        var rootID: String?
        var loadedIDs: Set<String> = []
        var hadThread = false
        let onThread: (String) -> Void

        init(tabID: UUID, taskID: UUID, directory workingDirectory: String?, resumeThreadID: String?, onThread: @escaping (String) -> Void) throws {
            self.tabID = tabID
            self.taskID = taskID
            self.onThread = onThread
            self.rootID = resumeThreadID
            directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("plume-cdx-" + String(UUID().uuidString.prefix(12)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            socketPath = directory.appendingPathComponent("s").path
            // macOS sockaddr_un has only 104 bytes. Fall back to /tmp rather
            // than accidentally exposing a TCP listener for a long temp path.
            guard socketPath.utf8.count < 104 else {
                try? FileManager.default.removeItem(at: directory)
                throw CodexUnixWebSocket.Failure.socket
            }
            let process = AgentProcess(label: "codex-terminal", onLine: { _ in }, onExit: { [weak self] status, _ in
                Task { @MainActor in self?.stop(failed: status != 0) }
            })
            self.process = process
            do {
                try process.start(arguments: ["codex", "app-server", "--listen", "unix://" + socketPath], workingDirectory: workingDirectory, environment: LoginShellCommand.plumeEnvironment)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            startObserver()
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !stopped else { return }
                    if SurfaceManager.shared.existingSession(for: tabID)?.hasExited == true {
                        Log.agent.info("Codex terminal surface exited; stopping its owned server")
                        stop(); return
                    }
                    if !observerFailed && Date().timeIntervalSince(lastRead) > 20 {
                        failObserver(reason: "observer request timed out")
                    }
                }
            }
        }

        func startObserver() {
            guard !stopped else { return }
            observerFailed = false
            lastRead = Date()
            connectionGeneration += 1
            let generation = connectionGeneration
            wire = CodexUnixWebSocket()
            client = CodexAppServerClient(writeLine: { [wire] in wire.send($0) })
            // Deliberately do not answer: approvals belong to the TUI. An
            // unsupported-method reply here could deny the TUI's own request.
            client.onServerRequest = { _, _, _ in }
            client.onNotification = { [weak self] method, params in
                guard let self, !stopped, method == "thread/started",
                      let thread = params["thread"], CodexTerminalMonitor.isConversationRoot(thread),
                      let id = thread["id"]?.stringValue else { return }
                rootID = id
                onThread(id)
            }
            background = CodexBackgroundTaskTracker(tabID: tabID) { [client] method, params in
                try await client!.send(method, params)
            }
            reader = Task { [weak self, wire] in
                for await line in wire.lines {
                    guard let self, !stopped, generation == connectionGeneration else { break }
                    client.receive(line)
                }
                if let self, generation == connectionGeneration {
                    failObserver(reason: "observer WebSocket closed")
                }
            }
            worker = Task { [weak self] in await self?.observe(generation: generation) }
        }

        /// Losing telemetry must never kill the user's real TUI turn. Drop
        /// stale activity immediately and retry only this read-only client.
        func failObserver(reason: String) {
            guard !stopped, !observerFailed else { return }
            Log.agent.error("Codex terminal tracking unavailable: \(reason, privacy: .public)")
            observerFailed = true
            connectionGeneration += 1
            worker?.cancel(); reader?.cancel()
            wire.close(); client?.stop(); background?.stop()
            StatusEngine.shared.setSubagentActivity(tabID: tabID, working: false)
            StatusEngine.shared.setStatus(.error, taskID: taskID, tabID: tabID, notifiable: false)
            guard reconnectAttempts < 3 else { return }
            reconnectAttempts += 1
            reconnect = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.startObserver()
            }
        }

        func observe(generation: Int) async {
            let wire = wire
            guard let client else { return }
            do {
                for _ in 0..<200 {
                    guard !stopped, !Task.isCancelled else { return }
                    if FileManager.default.fileExists(atPath: socketPath) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await wire.connect(path: socketPath)
                guard !stopped, !Task.isCancelled, generation == connectionGeneration else { return }
                _ = try await client.send("initialize", .object([
                    "clientInfo": .object(["name": .string("plume_terminal_observer"), "version": .string("1")]),
                    "capabilities": .object(["experimentalApi": .bool(true)])
                ]))
                guard !stopped, !Task.isCancelled, generation == connectionGeneration else { return }
                client.notify("initialized")
                while !stopped, !Task.isCancelled, generation == connectionGeneration {
                    try await refresh(client: client, generation: generation)
                    lastRead = Date()
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                if !stopped && !Task.isCancelled {
                    Log.agent.error("Codex terminal observer disconnected: \(String(describing: error), privacy: .public)")
                }
                if !Task.isCancelled && generation == connectionGeneration {
                    failObserver(reason: String(describing: error))
                }
            }
        }

        func refresh(client: CodexAppServerClient, generation: Int) async throws {
            var ids: [String] = [], cursor: String?, cursors: Set<String> = []
            repeat {
                var params: [String: JSONValue] = ["limit": .number(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let page = try await client.send("thread/loaded/list", .object(params))
                ids += page["data"]?.arrayValue?.compactMap(\.stringValue) ?? []
                cursor = page["nextCursor"]?.stringValue
                if let cursor, !cursors.insert(cursor).inserted { throw CodexUnixWebSocket.Failure.frame }
            } while cursor != nil
            var threads: [JSONValue] = []
            for id in ids {
                do {
                    let response = try await client.send("thread/read", .object(["threadId": .string(id), "includeTurns": .bool(false)]))
                    if let thread = response["thread"] { threads.append(thread) }
                } catch CodexAppServerClient.Failure.server(_, let message)
                    where message.localizedCaseInsensitiveContains("thread") &&
                        (message.localizedCaseInsensitiveContains("not found") || message.localizedCaseInsensitiveContains("not loaded")) {
                    // The TUI can unload a thread between listing and reading
                    // it. Other RPC/transport failures still fail the observer.
                    continue
                }
            }
            guard !stopped, !Task.isCancelled, generation == connectionGeneration else { return }
            loadedIDs = Set(threads.compactMap { $0["id"]?.stringValue })
            let roots = threads.filter(CodexTerminalMonitor.isConversationRoot)
            // The TUI can /new; only this private server's root conversations
            // exist here. Prefer the newest root and follow its children.
            let root = roots.first { $0["id"]?.stringValue == rootID }
                ?? roots.first { CodexTerminalMonitor.status($0["status"] ?? .null) == .working }
                ?? roots.max { ($0["createdAt"]?.doubleValue ?? 0) < ($1["createdAt"]?.doubleValue ?? 0) }
            if let root, let id = root["id"]?.stringValue {
                hadThread = true
                if rootID != id { rootID = id; onThread(id) }
                if let title = CodexThreadTitle.title(thread: root) { TitleStore.shared.setTitle(title, forTab: tabID) }
            }
            StatusEngine.shared.setStatus(CodexTerminalMonitor.aggregateStatus(threads),
                                         taskID: taskID, tabID: tabID, notifiable: !threads.isEmpty)
            // All descendants share this private server; detached children
            // remain real work even after the parent finishes its own turn.
            let childrenWorking = threads.contains { thread in
                thread["id"]?.stringValue != rootID && CodexTerminalMonitor.status(thread["status"] ?? .null) == .working
            }
            StatusEngine.shared.setSubagentActivity(tabID: tabID, working: childrenWorking)
            let presentIDs = Set(threads.compactMap { $0["id"]?.stringValue })
            background?.retainThreads(presentIDs)
            for id in presentIDs { background?.refresh(threadID: id) }
        }

        func stop(failed: Bool = false) {
            guard !stopped else { return }
            stopped = true
            worker?.cancel(); reader?.cancel(); watchdog?.cancel(); reconnect?.cancel()
            wire.close()
            client?.stop()
            background?.stop()
            StatusEngine.shared.setSubagentActivity(tabID: tabID, working: false)
            StatusEngine.shared.setStatus(failed ? .error : .awaitingReply, taskID: taskID, tabID: tabID, notifiable: false)
            process?.terminate(); process = nil
            try? FileManager.default.removeItem(at: directory)
            onStop?()
        }
    }
}
