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

    private var process: AgentProcess?
    /// Where outgoing lines go, reporting false once the transport is gone.
    /// Set when the process starts.
    private(set) var writeLine: ((String) -> Bool)?
    private var nextRequestNumber = 0
    private var pending: [CodexRPC.RequestID: CheckedContinuation<JSONValue, Error>] = [:]

    var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    var onServerRequest: ((_ id: CodexRPC.RequestID, _ method: String, _ params: JSONValue) -> Void)?
    var onExit: ((_ status: Int32, _ message: String?) -> Void)?

    /// `writeLine` is supplied only when there is no subprocess to own — a
    /// test driving the protocol directly. `start` sets it otherwise.
    init(writeLine: ((String) -> Bool)? = nil) {
        self.writeLine = writeLine
    }

    func start(workingDirectory: String?, environment: [String: String]) throws {
        let handler = AgentProcess(
            label: "codex",
            onLine: { [weak self] line in
                Task { @MainActor in self?.receive(line) }
            },
            onExit: { [weak self] status, errorLine in
                Task { @MainActor in self?.handleExit(status: status, message: errorLine) }
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

    func stop() {
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
        var fields: [String: JSONValue] = ["method": .string(method)]
        if let params { fields["params"] = params }
        guard let line = encode(fields) else { return }
        writeLine?(line)
    }

    func respond(to id: CodexRPC.RequestID, result: JSONValue) {
        guard let line = encode(["id": id.json, "result": result]) else { return }
        writeLine?(line)
    }

    /// Every server request must be answered. An unanswered one stalls the
    /// turn exactly the way an unanswered `can_use_tool` does, so anything
    /// Plume does not implement gets an error rather than silence.
    func respondUnsupported(to id: CodexRPC.RequestID, method: String) {
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
