import Foundation
import Observation

/// Account quota shared across Codex chats, kept separate from Claude quota.
/// Sparse updates refresh only the windows actually reported by the server.
/// The latest reading persists across launches.
@MainActor @Observable
final class CodexQuotaStore {
    static let shared = CodexQuotaStore(defaults: .standard)
    private var limits = CodexRateLimits()
    private var receivedAt: [String: Date] = [:]
    var windows: [CodexQuotaWindow] { limits.windows }

    /// Nil keeps the store in memory only, which is what tests want.
    @ObservationIgnored private let defaults: UserDefaults?
    static let defaultsKey = "codexQuotaSnapshot"

    init(defaults: UserDefaults? = nil, now: Date = Date()) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode(CodexQuotaSnapshot.self, from: data)
        else { return }
        let restored = stored.restored(now: now)
        limits = CodexRateLimits(windows: restored.windows)
        receivedAt = restored.receivedAt
    }

    func record(_ payload: JSONValue, at date: Date = Date()) {
        guard let object = payload.objectValue,
              object["rateLimitsByLimitId"] != nil || object["rateLimits"]?.objectValue != nil else { return }
        let oldWindows = limits.windows
        _ = limits.receive(payload)
        let windows = limits.windows
        let ids = Set(windows.map(\.id))
        receivedAt = receivedAt.filter { ids.contains($0.key) }
        if object["rateLimitsByLimitId"] != nil {
            for window in windows { receivedAt[window.id] = date }
        } else if let update = object["rateLimits"]?.objectValue {
            let oldBucketIDs = Set(oldWindows.map(\.bucketID))
            let bucketID = update["limitId"]?.stringValue
                ?? (oldBucketIDs.contains("codex") ? "codex" : oldBucketIDs.count == 1 ? oldWindows.first?.bucketID : nil)
            for window in windows where window.bucketID == bucketID {
                if update[window.slot.rawValue]?.objectValue != nil { receivedAt[window.id] = date }
            }
        }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        let snapshot = CodexQuotaSnapshot(windows: limits.windows, receivedAt: receivedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func isStale(_ window: CodexQuotaWindow, now: Date) -> Bool {
        guard let date = receivedAt[window.id] else { return false }
        return QuotaFreshness.isStale(receivedAt: date, now: now)
    }
}

/// The persisted form of `CodexQuotaStore`, keyed by `CodexQuotaWindow.id`.
struct CodexQuotaSnapshot: Equatable, Codable {
    let windows: [CodexQuotaWindow]
    let receivedAt: [String: Date]

    /// Any window that has reset since it was saved reads 0%, with no reset
    /// time until a live reading brings one.
    func restored(now: Date) -> CodexQuotaSnapshot {
        let windows = windows.map { window in
            let refilled = QuotaFreshness.hasRefilled(
                resetsAt: window.resetsAt,
                receivedAt: receivedAt[window.id] ?? now,
                windowLength: window.durationMinutes.map { TimeInterval($0) * 60 },
                now: now
            )
            guard refilled else { return window }
            return CodexQuotaWindow(
                bucketID: window.bucketID,
                bucketName: window.bucketName,
                slot: window.slot,
                usedPercent: 0,
                durationMinutes: window.durationMinutes,
                resetsAt: nil
            )
        }
        return CodexQuotaSnapshot(windows: windows, receivedAt: receivedAt)
    }
}
