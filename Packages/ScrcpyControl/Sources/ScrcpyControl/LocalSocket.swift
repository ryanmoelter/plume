import Foundation
import Network

enum LocalSocketError: Error {
    case failed(NWError)
    case cancelled
}

/// A TCP connection to the adb forward, with async receive and send.
final class LocalSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(port: UInt16, label: String) {
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        queue = DispatchQueue(label: "ScrcpyControl.\(label)")
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case let .failed(error), let .waiting(error):
                    if resumed.claim() {
                        connection.cancel()
                        continuation.resume(throwing: LocalSocketError.failed(error))
                    }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: LocalSocketError.cancelled) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Returns at least one byte, or nil once the peer has closed.
    func receive(maximum: Int = 1 << 20) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: LocalSocketError.failed(error))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Reads exactly `count` bytes, or returns nil if the peer closes first.
    func receive(exactly count: Int) async throws -> Data? {
        var out = Data()
        while out.count < count {
            guard let chunk = try await receive(maximum: count - out.count) else { return nil }
            out.append(chunk)
        }
        return out
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LocalSocketError.failed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
