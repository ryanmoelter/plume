import Foundation
import Observation

/// Account quota shared across Codex chats, kept separate from Claude quota.
/// Sparse updates refresh only the windows actually reported by the server.
@MainActor @Observable
final class CodexQuotaStore {
    static let shared = CodexQuotaStore()
    private var limits = CodexRateLimits()
    private var receivedAt: [String: Date] = [:]
    var windows: [CodexQuotaWindow] { limits.windows }

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
    }

    func isStale(_ window: CodexQuotaWindow, now: Date) -> Bool {
        guard let date = receivedAt[window.id] else { return false }
        return QuotaFreshness.isStale(receivedAt: date, now: now)
    }
}
