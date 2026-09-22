import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Attaches images dropped anywhere on a chat tab, not only on the
/// composer's one-line text view, which is too small a target to find.
///
/// The composer's own `NSTextView` still takes a drop over its text, so a
/// text drag there keeps inserting. `validateDrop` declines anything that
/// carries no image, so a text drag over the conversation is refused rather
/// than consumed.
struct ComposerImageDropDelegate: DropDelegate {
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    let isEnabled: Bool
    let attach: ([ChatImage]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && ComposerImageAttachment.hasImages(on: dragPasteboard)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    /// `NSItemProvider` only loads asynchronously, and `validateDrop` has to
    /// answer now, so both read the drag pasteboard directly.
    func performDrop(info: DropInfo) -> Bool {
        let images = ComposerImageAttachment.images(from: dragPasteboard)
        guard !images.isEmpty else { return false }
        attach(images)
        return true
    }

    private var dragPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
}
