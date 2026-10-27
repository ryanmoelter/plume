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

    struct ParseError: Error, Equatable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func parse(_ data: Data) throws -> StackJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Extra data") }
        return value
    }

    /// Two-space indentation, `ensure_ascii` escaping, and with `sortKeys`
    /// every object's keys in code point order.
    func rendered(sortKeys: Bool = false) -> String {
        var out = ""
        render(into: &out, depth: 0, sortKeys: sortKeys)
        return out
    }

    subscript(key: String) -> StackJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Python's string order: by code point, with no normalization.
    static func codePointPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
    }

    private func render(into out: inout String, depth: Int, sortKeys: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += Self.pythonRepr(value)
        case .string(let value): Self.escape(value, into: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            let inner = String(repeating: "  ", count: depth + 1)
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.render(into: &out, depth: depth + 1, sortKeys: sortKeys)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: depth) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let ordered = sortKeys ? members.sorted { Self.codePointPrecedes($0.key, $1.key) } : members
            let inner = String(repeating: "  ", count: depth + 1)
            out += "{\n"
            for (index, member) in ordered.enumerated() {
                out += inner
                Self.escape(member.key, into: &out)
                out += ": "
                member.value.render(into: &out, depth: depth + 1, sortKeys: sortKeys)
                out += index == ordered.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: depth) + "}"
        }
    }

    private static func pythonRepr(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return "\(value)"
    }

    private static func escape(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            default:
                if scalar.value >= 0x20 && scalar.value < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value > 0xFFFF {
                    let offset = scalar.value - 0x10000
                    out += hex(0xD800 + (offset >> 10)) + hex(0xDC00 + (offset & 0x3FF))
                } else {
                    out += hex(scalar.value)
                }
            }
        }
        out += "\""
    }

    private static func hex(_ unit: UInt32) -> String {
        let digits = String(unit, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func error(_ message: String) -> ParseError {
            ParseError(message: "\(message) (char \(index))")
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String, _ value: StackJSON) throws -> StackJSON {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else {
                throw error("Expecting value")
            }
            index += expected.count
            return value
        }

        mutating func value() throws -> StackJSON {
            guard index < bytes.count else { throw error("Expecting value") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try expect("true", .bool(true))
            case UInt8(ascii: "f"): return try expect("false", .bool(false))
            case UInt8(ascii: "n"): return try expect("null", .null)
            default: return try number()
            }
        }

        mutating func object() throws -> StackJSON {
            index += 1
            var members: [StackJSONMember] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw error("Expecting property name enclosed in double quotes")
                }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expecting ':' delimiter") }
                index += 1
                skipWhitespace()
                let item = try value()
                // A repeated key keeps its first position and its last value.
                if let existing = members.firstIndex(where: { $0.key == key }) {
                    members[existing].value = item
                } else {
                    members.append(StackJSONMember(key, item))
                }
                skipWhitespace()
                guard index < bytes.count else { throw error("Expecting ',' delimiter") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error("Expecting ',' delimiter")
            }
        }

        mutating func array() throws -> StackJSON {
            index += 1
            var items: [StackJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw error("Expecting ',' delimiter") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("Expecting ',' delimiter")
            }
        }

        mutating func hexUnit() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index ..< index + 4], encoding: .ascii),
                  let unit = UInt32(text, radix: 16)
            else { throw error("Invalid \\uXXXX escape") }
            index += 4
            return unit
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() throws {
                guard !run.isEmpty else { return }
                guard let text = String(bytes: run, encoding: .utf8) else { throw error("Invalid UTF-8") }
                scalars.append(contentsOf: text.unicodeScalars)
                run.removeAll()
            }
            while true {
                guard index < bytes.count else { throw error("Unterminated string") }
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") {
                    try flush()
                    return String(scalars)
                }
                if byte < 0x20 { throw error("Invalid control character") }
                guard byte == UInt8(ascii: "\\") else {
                    run.append(byte)
                    continue
                }
                try flush()
                guard index < bytes.count else { throw error("Unterminated string") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{8}")
                case UInt8(ascii: "f"): scalars.append("\u{C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var unit = try hexUnit()
                    if (0xD800 ..< 0xDC00).contains(unit),
                       index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try hexUnit()
                        if (0xDC00 ..< 0xE000).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                default:
                    throw error("Invalid \\escape")
                }
            }
        }

        mutating func number() throws -> StackJSON {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int {
                let from = index
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) { index += 1 }
                return index - from
            }
            guard digits() > 0 else {
                index = start
                throw error("Expecting value")
            }
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                isInteger = false
                guard digits() > 0 else { throw error("Expecting value") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                isInteger = false
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("Expecting value") }
            }
            let text = String(decoding: bytes[start ..< index], as: UTF8.self)
            if isInteger, let value = Int(text) { return .int(value) }
            guard let value = Double(text) else { throw error("Invalid number") }
            return .double(value)
        }
    }
}
