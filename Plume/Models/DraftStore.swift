import Foundation
import Observation

/// The unsent composer text and attached images of every tab, and whether
/// that text is a shell command rather than a message.
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
/// character, so a literal `**x**` pasted as plain text would come back bold
/// if a tab switch had to re-parse the markdown to restore it.
@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [UUID: String] = [:]
    private var attachments: [UUID: [ChatImage]] = [:]
    /// Tabs whose composer is in command mode. Kept beside the draft because
    /// it is part of the same unsent state: the `!` that starts the mode is
    /// taken out of the text, so nothing in the draft records it.
    private var commandModeTabs: Set<UUID> = []
    @ObservationIgnored private var documents: [UUID: NSAttributedString] = [:]

    init() {}

    func attachments(forTab id: UUID) -> [ChatImage] {
        attachments[id] ?? []
    }

    func attach(_ images: [ChatImage], toTab id: UUID) {
        guard !images.isEmpty else { return }
        attachments[id, default: []].append(contentsOf: images)
    }

    func removeAttachment(at index: Int, fromTab id: UUID) {
        guard var existing = attachments[id], existing.indices.contains(index) else { return }
        existing.remove(at: index)
        attachments[id] = existing.isEmpty ? nil : existing
    }

    func clearAttachments(forTab id: UUID) {
        attachments.removeValue(forKey: id)
    }

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

    func isCommandMode(forTab id: UUID) -> Bool {
        commandModeTabs.contains(id)
    }

    func setCommandMode(_ isCommandMode: Bool, forTab id: UUID) {
        if isCommandMode {
            commandModeTabs.insert(id)
        } else {
            commandModeTabs.remove(id)
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
        attachments.removeValue(forKey: tabID)
        commandModeTabs.remove(tabID)
        documents.removeValue(forKey: tabID)
    }

    func reset() {
        drafts.removeAll()
        attachments.removeAll()
        commandModeTabs.removeAll()
        documents.removeAll()
    }
}
