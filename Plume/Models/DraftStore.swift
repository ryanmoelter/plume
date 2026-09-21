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

    func setDraft(_ text: String, forTab id: UUID) {
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

    func forget(tabID: UUID) {
        drafts.removeValue(forKey: tabID)
        attachments.removeValue(forKey: tabID)
        commandModeTabs.remove(tabID)
    }

    func reset() {
        drafts.removeAll()
        attachments.removeAll()
        commandModeTabs.removeAll()
    }
}
