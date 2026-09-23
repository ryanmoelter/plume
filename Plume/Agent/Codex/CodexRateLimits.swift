import Foundation

/// One Codex account quota window.
///
/// Codex exposes windows by bucket and slot, rather than promising a fixed
/// five-hour/seven-day pair. Keep the provider's identity and duration here so
/// the UI can show what the server actually returned.
struct CodexQuotaWindow: Identifiable, Equatable, Sendable {
    enum Slot: String, CaseIterable, Sendable {
        case primary
        case secondary

        var sortOrder: Int {
            switch self {
            case .primary: 0
            case .secondary: 1
            }
        }

        var label: String { rawValue.capitalized }
    }

    /// The metered limit bucket, such as `codex`. Nil means the server sent
    /// the backwards-compatible single-bucket view without an identifier.
    let bucketID: String?
    let bucketName: String?
    let slot: Slot
    let usedPercent: Int
    /// Nil is meaningful: the backend knows the utilization but not this
    /// window's duration.
    let durationMinutes: Int?
    /// Nil is meaningful: the backend did not provide a reset timestamp.
    let resetsAt: Date?

    var id: String {
        "\(bucketID ?? "unlabeled"):\(slot.rawValue)"
    }

    var utilization: Double { Double(usedPercent) / 100 }
}

/// The Codex account rate-limit snapshot plus sparse rolling updates.
///
/// `account/rateLimits/read` may contain a multi-bucket `rateLimitsByLimitId`
/// map, while `account/rateLimits/updated` carries one sparse `rateLimits`
/// snapshot. A full map replaces the previous snapshot. A rolling update
/// patches only the bucket it names; an explicit null primary/secondary window
/// removes that window. Omitted metadata is retained on sparse updates; explicit null metadata
/// clears the corresponding reading.
struct CodexRateLimits: Equatable {
    /// All currently known windows, retaining bucket identity, slot and
    /// duration. Sorted by bucket ID, then primary before secondary.
    var windows: [CodexQuotaWindow] {
        buckets.values
            .sorted { lhs, rhs in
                (lhs.bucketID ?? "") < (rhs.bucketID ?? "")
            }
            .flatMap { bucket in
                [bucket.primary, bucket.secondary]
                    .compactMap { $0 }
                    .sorted { $0.slot.sortOrder < $1.slot.sortOrder }
            }
    }

    private struct Bucket: Equatable {
        var bucketID: String?
        var bucketName: String?
        var primary: CodexQuotaWindow?
        var secondary: CodexQuotaWindow?
    }

    private static let unlabeledBucketKey = "\u{0}"
    private var buckets: [String: Bucket] = [:]

    /// Applies a full account response or a sparse account notification.
    /// Returns the old Claude-shaped view for the short compatibility period
    /// while the shared session/UI are being migrated to `windows`.
    mutating func receive(_ payload: JSONValue) -> RateLimitInfo? {
        guard let root = payload.objectValue else { return compatibilityInfo }

        if root.keys.contains("rateLimitsByLimitId") {
            applyFullSnapshot(root)
        } else if let snapshot = root["rateLimits"], snapshot != .null {
            applySparseSnapshot(snapshot)
        }

        return compatibilityInfo
    }

    private mutating func applyFullSnapshot(_ root: [String: JSONValue]) {
        if case let .object(rawBuckets)? = root["rateLimitsByLimitId"], !rawBuckets.isEmpty {
            var replacement: [String: Bucket] = [:]
            for (key, value) in rawBuckets {
                guard let bucket = decodeBucket(
                    value,
                    bucketID: key,
                    existing: nil,
                    sparse: false
                ) else { continue }
                replacement[key] = bucket
            }
            buckets = replacement
            return
        }

        // Older or account types without a multi-bucket response still expose
        // the required single-bucket `rateLimits` field.
        buckets = [:]
        if let snapshot = root["rateLimits"], snapshot != .null,
           let bucket = decodeBucket(snapshot, bucketID: nil, existing: nil, sparse: false) {
            buckets[key(for: bucket.bucketID)] = bucket
        }
    }

    private mutating func applySparseSnapshot(_ value: JSONValue) {
        guard let object = value.objectValue else { return }

        let requestedID = object["limitId"]?.stringValue
        let bucketID = requestedID ?? fallbackBucketID
        let key = key(for: bucketID)
        let existing = buckets[key]
        guard let bucket = decodeBucket(
            value,
            bucketID: bucketID,
            existing: existing,
            sparse: true
        ) else { return }
        buckets[key] = bucket
    }

    private var fallbackBucketID: String? {
        if buckets["codex"] != nil { return "codex" }
        guard buckets.count == 1 else { return nil }
        return buckets.values.first?.bucketID
    }

    private func decodeBucket(
        _ value: JSONValue,
        bucketID requestedID: String?,
        existing: Bucket?,
        sparse: Bool
    ) -> Bucket? {
        guard let object = value.objectValue else { return nil }

        let bucketID = requestedID ?? object["limitId"]?.stringValue ?? existing?.bucketID
        let bucketName = string(
            object["limitName"],
            old: existing?.bucketName,
            sparse: sparse
        )
        let primary = decodeWindow(
            object["primary"],
            bucketID: bucketID,
            bucketName: bucketName,
            slot: .primary,
            existing: existing?.primary,
            sparse: sparse
        )
        let secondary = decodeWindow(
            object["secondary"],
            bucketID: bucketID,
            bucketName: bucketName,
            slot: .secondary,
            existing: existing?.secondary,
            sparse: sparse
        )

        return Bucket(
            bucketID: bucketID,
            bucketName: bucketName,
            primary: primary,
            secondary: secondary
        )
    }

    private func decodeWindow(
        _ value: JSONValue?,
        bucketID: String?,
        bucketName: String?,
        slot: CodexQuotaWindow.Slot,
        existing: CodexQuotaWindow?,
        sparse: Bool
    ) -> CodexQuotaWindow? {
        guard let value else { return sparse ? existing : nil }
        if value == .null { return nil }
        guard let object = value.objectValue,
              let usedPercent = object["usedPercent"]?.intValue
        else { return sparse ? existing : nil }

        let durationMinutes = integer(
            object["windowDurationMins"],
            old: existing?.durationMinutes,
            sparse: sparse
        )
        let resetsAt = date(
            object["resetsAt"],
            old: existing?.resetsAt,
            sparse: sparse
        )
        return CodexQuotaWindow(
            bucketID: bucketID,
            bucketName: bucketName,
            slot: slot,
            usedPercent: usedPercent,
            durationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }

    private func string(_ value: JSONValue?, old: String?, sparse: Bool) -> String? {
        guard let value else { return sparse ? old : nil }
        return value.stringValue
    }

    private func integer(_ value: JSONValue?, old: Int?, sparse: Bool) -> Int? {
        guard let value else { return sparse ? old : nil }
        return value.intValue
    }

    private func date(_ value: JSONValue?, old: Date?, sparse: Bool) -> Date? {
        guard let value else { return sparse ? old : nil }
        guard let seconds = value.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func key(for bucketID: String?) -> String {
        bucketID ?? Self.unlabeledBucketKey
    }

    /// Maps the Codex snapshot to the old two-slot model for callers that have
    /// not migrated yet. Unknown durations stay visible through `windows`, but
    /// do not get mislabeled as five-hour or seven-day quota.
    private var compatibilityInfo: RateLimitInfo? {
        let bucket = buckets["codex"] ?? buckets.values.sorted {
            ($0.bucketID ?? "") < ($1.bucketID ?? "")
        }.first
        guard let bucket else { return nil }

        var fiveHour: RateLimitInfo.Window?
        var sevenDay: RateLimitInfo.Window?
        for window in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
            let mapped = RateLimitInfo.Window(
                utilization: window.utilization,
                resetsAt: window.resetsAt
            )
            switch window.durationMinutes {
            case 300: fiveHour = mapped
            case 10_080: sevenDay = mapped
            default: break
            }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return RateLimitInfo(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            isUsingOverage: false
        )
    }
}
