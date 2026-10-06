import Foundation

enum KeyboardRemoval {
    /// A task that never started has nothing to archive, and the context menu
    /// hides Archive for it.
    static func verbForDeleteKey(hasNeverStarted: Bool) -> WorktreeRemovalVerb {
        hasNeverStarted ? .delete : .archive
    }

    /// An empty task has no tab for ⌘W to close, so ⌘W deletes the task.
    static func deletesTaskOnClose(tabCount: Int) -> Bool {
        tabCount == 0
    }
}
