import Foundation

/// What fills the context window, by category, from a `get_context_usage`
/// reply. See `docs/headless-protocol.md`.
nonisolated struct ContextUsageBreakdown: Equatable {
    struct Category: Equatable {
        let name: String
        let tokens: Int
        /// `used`, `deferred`, `buffer` or `free` as of CLI 2.1.296. Nil when
        /// the reply leaves it out.
        let kind: String?
        let isDeferred: Bool
    }

    let categories: [Category]
    let totalTokens: Int?
    let maxTokens: Int?

    /// Free space restates the meter's own remainder, and deferred tools are
    /// not loaded into context at all, so neither belongs in a list of what
    /// the window holds.
    var displayedCategories: [Category] {
        categories.filter { $0.kind != "free" && $0.kind != "deferred" && !$0.isDeferred }
    }

    /// Nil when the payload has no usable category, so a reply in an
    /// unexpected shape shows no breakdown rather than an empty one.
    init?(payload: [String: JSONValue]) {
        let categories = (payload["categories"]?.arrayValue ?? []).compactMap { entry -> Category? in
            guard let fields = entry.objectValue,
                  let name = fields["name"]?.stringValue,
                  let tokens = fields["tokens"]?.intValue
            else { return nil }
            return Category(
                name: name,
                tokens: tokens,
                kind: fields["kind"]?.stringValue,
                isDeferred: fields["isDeferred"]?.boolValue ?? false
            )
        }
        guard !categories.isEmpty else { return nil }
        self.categories = categories
        totalTokens = payload["totalTokens"]?.intValue
        maxTokens = payload["maxTokens"]?.intValue
    }
}
