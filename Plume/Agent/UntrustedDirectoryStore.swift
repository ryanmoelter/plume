import Foundation
import Observation

/// Tabs `AgentLauncher` refused to spawn because Claude Code has not been
/// told to trust their directory — keyed by tab ID, the same shape as
/// `StatusEngine`.
///
/// The chat view reads this to show a message in place of the composer, for
/// a tab whose conversation is empty. A refusal that follows a sent message
/// is reported through the session's own `startFailure` instead, so it lands
/// beside the message rather than replacing it.
@MainActor
@Observable
final class UntrustedDirectoryStore {
    static let shared = UntrustedDirectoryStore()

    private(set) var untrustedPaths: [UUID: String] = [:]

    init() {}

    func markUntrusted(tabID: UUID, path: String) {
        untrustedPaths[tabID] = path
    }

    func clear(tabID: UUID) {
        untrustedPaths.removeValue(forKey: tabID)
    }

    func path(forTab tabID: UUID) -> String? {
        untrustedPaths[tabID]
    }
}
