import Foundation
import os

/// Speaks the `codex app-server` protocol over one subprocess.
///
/// Knows the envelope and nothing above it: correlating replies, delivering
/// notifications and server requests, and answering by ID. `CodexSession`
/// supplies meaning, the way `HeadlessSession` does for stream-json.
@MainActor
final class CodexAppServerClient {
    enum Failure: Error, Equatable {
        case notRunning
        case exited(status: Int32, message: String?)
        case server(code: Int, message: String)
    }

    private let sharedServer: CodexSharedAppServer?
    var usesSharedServer: Bool { sharedServer != nil }
    var sharedRemoteControl: CodexRemoteControl? { sharedServer?.remoteControl }

    static func sharedSessionClient() -> CodexAppServerClient {
        CodexAppServerClient(sharedServer: .shared)
    }

    init(sharedServer: CodexSharedAppServer) {
        self.sharedServer = sharedServer
        launchesProcess = false
    }

    private var process: AgentProcess?
    private let launchesProcess: Bool
    /// Where outgoing lines go, reporting false once the transport is gone.
    /// Set when the process starts.
    private(set) var writeLine: ((String) -> Bool)?
    private var lifecycleGeneration = 0
    private var nextRequestNumber = 0
    private var pending: [CodexRPC.RequestID: CheckedContinuation<JSONValue, Error>] = [:]

    /// `AgentProcess` delivers bytes in order on its serial queue. Crossing to
    /// MainActor with one independent Task per line can reorder those lines,
    /// including a turn notification overtaking the response that started it.
    private lazy var incomingEvents = OrderedCodexEvents { [weak self] event in
        switch event {
        case .line(let line, let generation):
            if self?.lifecycleGeneration == generation { self?.receive(line) }
        case .exit(let status, let message, let generation):
            if self?.lifecycleGeneration == generation { self?.handleExit(status: status, message: message) }
        }
    }

    var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    var onServerRequest: ((_ id: CodexRPC.RequestID, _ method: String, _ params: JSONValue) -> Void)?
    var onExit: ((_ status: Int32, _ message: String?) -> Void)?

    /// `writeLine` is supplied only when there is no subprocess to own — a
    /// test driving the protocol directly. `start` sets it otherwise.
    init(writeLine: ((String) -> Bool)? = nil) {
        self.writeLine = writeLine
        sharedServer = nil
        launchesProcess = writeLine == nil
    }

    func start(workingDirectory: String?, environment: [String: String]) throws {
        if let sharedServer {
            try sharedServer.attach(self, workingDirectory: workingDirectory, environment: environment)
            return
        }
        // An injected transport already is the running connection. This lets
        // tests drive the complete handshake without launching or paying for
        // a real Codex process.
        guard launchesProcess else { return }
        guard process == nil else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let incomingEvents = incomingEvents
        let handler = AgentProcess(
            label: "codex",
            onLine: { line in
                incomingEvents.enqueue(.line(line, generation))
            },
            onExit: { status, errorLine in
                incomingEvents.enqueue(.exit(status, errorLine, generation))
            }
        )
        try handler.start(
            arguments: CodexCommand.arguments(),
            workingDirectory: workingDirectory,
            environment: environment
        )
        process = handler
        writeLine = { [weak handler] line in handler?.send(line: line) ?? false }
    }

    var processIdentifier: pid_t? { sharedServer?.processIdentifier ?? process?.processIdentifier }

    func releaseThread(threadID: String, turnID: String?) {
        sharedServer?.releaseThread(threadID: threadID, turnID: turnID)
    }

    func stop() {
        lifecycleGeneration += 1
        sharedServer?.detach(self)
        process?.terminate()
        process = nil
        writeLine = nil
        drainPending(with: .notRunning)
    }

    /// Sends a request and waits for its reply.
    @discardableResult
    func send(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        nextRequestNumber += 1
        let id = CodexRPC.RequestID.number(nextRequestNumber)
        if let sharedServer {
            let generation = lifecycleGeneration
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { [weak self] in
                    do {
                        guard let self, self.lifecycleGeneration == generation else { throw Failure.notRunning }
                        let result = try await sharedServer.send(from: self, method: method, params: params)
                        self.pending.removeValue(forKey: id)?.resume(returning: result)
                    } catch {
                        self?.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        }
        let line = encode(["id": id.json, "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            guard let line, writeLine?(line) == true else {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: Failure.notRunning)
                return
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue? = nil) {
        if let sharedServer { sharedServer.notify(from: self, method: method, params: params); return }
        var fields: [String: JSONValue] = ["method": .string(method)]
        if let params { fields["params"] = params }
        guard let line = encode(fields) else { return }
        writeLine?(line)
    }

    func respond(to id: CodexRPC.RequestID, result: JSONValue) {
        if let sharedServer { sharedServer.respond(from: self, id: id, result: result); return }
        guard let line = encode(["id": id.json, "result": result]) else { return }
        writeLine?(line)
    }

    /// Every server request must be answered. An unanswered one stalls the
    /// turn exactly the way an unanswered `can_use_tool` does, so anything
    /// Plume does not implement gets an error rather than silence.
    func respondUnsupported(to id: CodexRPC.RequestID, method: String) {
        if let sharedServer { sharedServer.respondUnsupported(from: self, id: id, method: method); return }
        let error = JSONValue.object([
            "code": .number(-32601),
            "message": .string("Plume does not implement \(method)")
        ])
        guard let line = encode(["id": id.json, "error": error]) else { return }
        writeLine?(line)
    }

    func receive(_ line: String) {
        guard let incoming = CodexRPC.decode(line: line) else {
            Log.agent.error("Undecodable codex line")
            return
        }
        switch incoming {
        case .response(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let error):
            pending.removeValue(forKey: id)?
                .resume(throwing: Failure.server(code: error.code, message: error.message))
        case .serverRequest(let id, let method, let params):
            if let onServerRequest {
                onServerRequest(id, method, params)
            } else {
                respondUnsupported(to: id, method: method)
            }
        case .notification(let method, let params):
            onNotification?(method, params)
        }
    }

    /// Exercises the same ordered actor hop as subprocess output.
    func enqueueForTesting(_ line: String) {
        incomingEvents.enqueue(.line(line, lifecycleGeneration))
    }

    func handleExit(status: Int32, message: String?) {
        process = nil
        writeLine = nil
        drainPending(with: .exited(status: status, message: message))
        onExit?(status, message)
    }

    /// A request whose reply can never arrive must fail, or its caller awaits
    /// forever and takes the chat's turn with it.
    private func drainPending(with failure: Failure) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: failure) }
    }

    private func encode(_ fields: [String: JSONValue]) -> String? {
        let encoder = JSONEncoder()
        // Every method name is a path, and the default escaping renders
        // `thread/start` as `thread\/start`.
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(JSONValue.object(fields)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum CodexTransportEvent: Sendable {
    case line(String, Int)
    case exit(Int32, String?, Int)
}

/// A lock protects the tiny synchronous producer side; one consumer Task
/// drains the FIFO on MainActor. Starting a Task per event does not guarantee
/// FIFO execution even though the source callbacks themselves are ordered.
private final class OrderedCodexEvents: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (CodexTransportEvent) -> Void

    private let lock = NSLock()
    private let handler: Handler
    private var events: [CodexTransportEvent] = []
    private var isDraining = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func enqueue(_ event: CodexTransportEvent) {
        lock.lock()
        events.append(event)
        let shouldStart = !isDraining
        if shouldStart { isDraining = true }
        lock.unlock()

        if shouldStart {
            Task { await drain() }
        }
    }

    private func drain() async {
        while let event = next() {
            await handler(event)
        }
    }

    private func next() -> CodexTransportEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else {
            isDraining = false
            return nil
        }
        return events.removeFirst()
    }
}
