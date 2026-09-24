import Foundation

/// The `codex app-server` envelope.
///
/// JSON-RPC-shaped rather than JSON-RPC 2.0: the server omits `jsonrpc`
/// entirely and accepts requests without it, so nothing here writes or
/// requires that field. See `docs/codex-protocol.md`.
nonisolated enum CodexRPC {
    /// Either form the protocol allows. Plume only ever mints integers; the
    /// string case exists because a server request may carry one.
    enum RequestID: Hashable, Codable {
        case number(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    struct ErrorBody: Decodable, Equatable {
        let code: Int
        let message: String
    }

    /// One decoded line. `params` and `result` stay as raw JSON so an unknown
    /// method costs a lookup rather than a decode failure — the protocol grows
    /// between Codex releases and Plume reads a small corner of it.
    enum Incoming {
        case response(id: RequestID, result: JSONValue)
        case failure(id: RequestID, error: ErrorBody)
        case serverRequest(id: RequestID, method: String, params: JSONValue)
        case notification(method: String, params: JSONValue)
    }

    /// Routes by shape, matching the protocol's own union: a `method` with an
    /// `id` is a request, a `method` alone is a notification, and anything
    /// else is a reply to something Plume sent.
    static func decode(line: String) -> Incoming? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = root
        else { return nil }

        let id = fields["id"].flatMap(RequestID.init(json:))

        if case .string(let method)? = fields["method"] {
            let params = fields["params"] ?? .null
            if let id { return .serverRequest(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }

        guard let id else { return nil }
        if let error = fields["error"], let body = ErrorBody(json: error) {
            return .failure(id: id, error: body)
        }
        return .response(id: id, result: fields["result"] ?? .null)
    }
}

extension CodexRPC.RequestID {
    init?(json: JSONValue) {
        switch json {
        case .number(let value): self = .number(Int(value))
        case .string(let value): self = .string(value)
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .number(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }
}

extension CodexRPC.ErrorBody {
    init?(json: JSONValue) {
        guard case .object(let fields) = json,
              case .string(let message)? = fields["message"]
        else { return nil }
        let code: Int
        if case .number(let value)? = fields["code"] { code = Int(value) } else { code = 0 }
        self.init(code: code, message: message)
    }
}
