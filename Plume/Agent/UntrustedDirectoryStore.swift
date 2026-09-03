import Foundation
import Observation

/// Tabs `AgentLauncher` refused to spawn because Claude Code has not been
/// told to trust their directory — keyed by tab ID, the same shape as
/// `StatusEngine`.
///
/// The chat view reads this to show a message in place of the composer,
/// since a refused launch leaves no transcript to put the message in.
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
