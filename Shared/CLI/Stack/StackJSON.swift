import Foundation

nonisolated struct StackJSONMember: Equatable, Sendable {
    var key: String
    var value: StackJSON

    init(_ key: String, _ value: StackJSON) {
        self.key = key
        self.value = value
    }
}

/// A JSON value that keeps object members in order and renders exactly as
/// Python's `json.dumps(…, indent=2)` does, so `branches.json` and
/// `stack list --json` stay byte-identical to what other copies of `stack`
/// write and read.
nonisolated enum StackJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([StackJSON])
    case object([StackJSONMember])

    struct ParseError: Error, Equatable {
        var message: String
    }

    static func parse(_ data: Data) throws -> StackJSON {
        throw ParseError(message: "not implemented")
    }

    /// Two-space indentation, `ensure_ascii` escaping, and with `sortKeys`
    /// every object's keys in code point order.
    func rendered(sortKeys: Bool = false) -> String {
        ""
    }

    subscript(key: String) -> StackJSON? {
        nil
    }

    /// Python's string order: by code point, with no normalization.
    static func codePointPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        false
    }
}
