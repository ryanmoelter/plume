import Foundation
import Observation

/// The unsent composer text of every tab.
///
/// A chat tab's view is unmounted whenever it stops being the selected tab,
/// so a draft held as view state disappears the moment the user looks at
/// anything else. Keeping it here, keyed by tab, is what lets a half-written
/// message survive a tab or task switch.
///
/// In memory only, like every other live-session fact — a draft is not worth
/// persisting across launches.
@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [UUID: String] = [:]

    init() {}

    func draft(forTab id: UUID) -> String {
        drafts[id] ?? ""
    }

    func setDraft(_ text: String, forTab id: UUID) {
        if text.isEmpty {
            drafts.removeValue(forKey: id)
        } else {
            drafts[id] = text
        }
    }

    func forget(tabID: UUID) {
        drafts.removeValue(forKey: tabID)
    }

    func reset() {
        drafts.removeAll()
    }
}
