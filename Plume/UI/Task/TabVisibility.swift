import Foundation

/// Whether a mounted tab is on screen, and whether it is the focused one.
///
/// Every tab of the selected task stays mounted so its terminal keeps
/// running, so "mounted" says nothing about visibility and each tab has to be
/// told. On screen and focused differ only while the task is split: both
/// panes render, but only the focused one takes first responder. Only the
/// tab clause appears here: a task that isn't selected is unmounted entirely,
/// and an unmounted view has no window, which already stops it rendering.
/// Mounting several tasks at once would need that second clause added.
enum TabVisibility {
    static func isOnScreen(tabID: UUID, paneTabIDs: [UUID]) -> Bool {
        paneTabIDs.contains(tabID)
    }

    static func isFocused(tabID: UUID, selectedTabID: UUID?) -> Bool {
        tabID == selectedTabID
    }
}
