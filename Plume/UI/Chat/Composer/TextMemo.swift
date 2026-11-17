import Foundation
import Synchronization

/// The last few results of a pure function of a text, so the composer's
/// styler, decorations, caret snapping and editing commands share one parse
/// of each version of the draft instead of each parsing it again.
///
/// Texts match UTF-16 unit for unit, not by `==`: canonically equivalent
/// strings compare equal but have different UTF-16 offsets, and every parse
/// here is a list of UTF-16 ranges.
nonisolated final class TextMemo<Value: Sendable>: Sendable {
    private let capacity: Int
    private let entries = Mutex<[(text: String, value: Value)]>([])

    init(capacity: Int = 4) {
        self.capacity = capacity
    }

    func value(for text: String, compute: (String) -> Value) -> Value {
        if let hit = entries.withLock({ entries -> Value? in
            guard let index = entries.firstIndex(where: { Self.isIdentical($0.text, text) }) else { return nil }
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.value
        }) {
            return hit
        }
        let value = compute(text)
        entries.withLock { entries in
            entries.insert((text, value), at: 0)
            if entries.count > capacity { entries.removeLast() }
        }
        return value
    }

    /// A bridged draft compares in place, without being transcoded.
    private static func isIdentical(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs as NSString
        let right = rhs as NSString
        return left === right || (left.length == right.length && left.isEqual(to: rhs))
    }
}
