import Foundation

/// How many tokens something used, in the coarsest terms that still say it.
nonisolated enum TokenCount {
    static func formatted(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}
