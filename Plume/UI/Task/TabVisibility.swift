import Foundation

/// Whether a mounted tab is the one actually on screen.
///
/// Every tab of the selected task stays mounted so its terminal keeps
/// running, so "mounted" says nothing about visibility and each tab has to be
/// told. Only the tab clause appears here: a task that isn't selected is
/// unmounted entirely, and an unmounted view has no window, which already
/// stops it rendering. Mounting several tasks at once would need that second
/// clause added.
enum TabVisibility {
    static func isOnScreen(tabID: UUID, selectedTabID: UUID?) -> Bool {
        tabID == selectedTabID
    }
}
