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
///
/// A draft is kept twice: as markdown, which is what a send and any future
/// persistence use, and as the composer's own attributed document. The second
/// copy exists because the composer never escapes a literal markdown
/// character, so a pasted literal `**x**` would come back bold if a tab switch
/// had to re-parse the markdown to restore it.
@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [UUID: String] = [:]
    @ObservationIgnored private var documents: [UUID: NSAttributedString] = [:]

    init() {}

    func draft(forTab id: UUID) -> String {
        drafts[id] ?? ""
    }

    /// Setting the markdown drops any attributed document behind it: every
    /// caller but the composer's own echo is replacing the draft wholesale,
    /// and the composer writes its snapshot back immediately afterwards.
    func setDraft(_ text: String, forTab id: UUID) {
        documents.removeValue(forKey: id)
        if text.isEmpty {
            drafts.removeValue(forKey: id)
        } else {
            drafts[id] = text
        }
    }

    /// The composer document behind `draft(forTab:)`, when the composer has
    /// been mounted since the draft was last set from elsewhere.
    func document(forTab id: UUID) -> NSAttributedString? {
        documents[id]
    }

    func setDocument(_ document: NSAttributedString, forTab id: UUID) {
        if document.length == 0 {
            documents.removeValue(forKey: id)
        } else {
            documents[id] = document
        }
    }

    func forget(tabID: UUID) {
        drafts.removeValue(forKey: tabID)
        documents.removeValue(forKey: tabID)
    }

    func reset() {
        drafts.removeAll()
        documents.removeAll()
    }
}
