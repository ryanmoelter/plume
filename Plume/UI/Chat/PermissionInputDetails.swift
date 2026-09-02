import Foundation

/// A permission request's `input`, flattened into labelled lines for display.
///
/// The raw JSON is unreadable in a decision prompt, so the fields most worth
/// seeing come first in a known order and everything else follows
/// alphabetically. Long values (a file's whole `content`) are shown whole —
/// the view bounds them, not this.
enum PermissionInputDetails {
    struct Field: Identifiable, Equatable {
        let key: String
        let value: String
        /// Rendered monospaced, for commands, paths and file bodies.
        let isCode: Bool

        var id: String { key }
    }

    private static let leadingKeys = [
        "command", "file_path", "path", "pattern", "url", "old_string", "new_string", "content", "prompt"
    ]

    private static let codeKeys: Set<String> = [
        "command", "file_path", "path", "pattern", "url", "old_string", "new_string", "content"
    ]

    static func fields(for input: [String: JSONValue]) -> [Field] {
        let ordered = input.keys.sorted { left, right in
            switch (leadingKeys.firstIndex(of: left), leadingKeys.firstIndex(of: right)) {
            case let (lhs?, rhs?): return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return ordered.compactMap { key in
            guard let value = input[key], let text = display(value), !text.isEmpty else { return nil }
            return Field(key: key, value: text, isCode: codeKeys.contains(key))
        }
    }

    private static func display(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .bool(let flag): return String(flag)
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .null: return nil
        case .array(let values):
            return values.compactMap(display).joined(separator: ", ")
        case .object:
            guard let data = try? JSONEncoder.prettyPermissionInput.encode(value) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

private extension JSONEncoder {
    static var prettyPermissionInput: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
