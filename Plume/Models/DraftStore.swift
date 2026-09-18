import Foundation
import Observation

/// The unsent composer text and attached images of every tab.
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

    func forget(tabID: UUID) {
        drafts.removeValue(forKey: tabID)
        attachments.removeValue(forKey: tabID)
    }

    func reset() {
        drafts.removeAll()
        attachments.removeAll()
    }
}
