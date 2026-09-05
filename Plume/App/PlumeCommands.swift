import AppKit
import SwiftUI

struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ShowArchiveActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Actions the menu bar performs on the selected task. Nil when nothing is
/// selected, which disables the whole Task menu.
struct TaskCommands {
    let addTab: (TabKind) -> Void
    let selectTab: (Int) -> Void
    let cycleTab: (Int) -> Void
    /// Returns whether a tab was actually closed, so ⌘W can fall back to
    /// closing the window when the task has none.
    let closeSelectedTab: () -> Bool
    let archiveSelectedTask: () -> Void
    /// Nil when the selected tab has no stored session to discard.
    let startFreshSelectedTab: (() -> Void)?
}

struct TaskCommandsKey: FocusedValueKey {
    typealias Value = TaskCommands
}

extension FocusedValues {
    var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }

    var showArchiveAction: (() -> Void)? {
        get { self[ShowArchiveActionKey.self] }
        set { self[ShowArchiveActionKey.self] = newValue }
    }

    var taskCommands: TaskCommands? {
        get { self[TaskCommandsKey.self] }
        set { self[TaskCommandsKey.self] = newValue }
    }
}

struct PlumeCommands: Commands {
    @FocusedValue(\.newTaskAction) private var newTask
    @FocusedValue(\.showArchiveAction) private var showArchive
    @FocusedValue(\.taskCommands) private var task

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { newTask?() }
                .keyboardShortcut("n")
                .disabled(newTask == nil)

            Button("New Agent Tab") { task?.addTab(.agent) }
                .keyboardShortcut("t")
                .disabled(task == nil)

            Button("New Terminal Tab") { task?.addTab(.terminal) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(task == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Show Archive…") { showArchive?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(showArchive == nil)
        }

        // Replaces rather than inserts after: `.saveItem` is where AppKit's
        // own "Close Window" lives, and two items sharing ⌘W leaves AppKit's
        // in charge. This item covers both cases itself — closing the
        // selected tab when there is one, the window otherwise — so it
        // never needs to be disabled.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if task?.closeSelectedTab() != true {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")

            Button("Archive Task") { task?.archiveSelectedTask() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(task == nil)
        }

        CommandMenu("Tab") {
            Button("Next Tab") { task?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(task == nil)
            Button("Previous Tab") { task?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(task == nil)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { task?.selectTab(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                    .disabled(task == nil)
            }

            Divider()

            Button("Start Fresh Conversation…") { task?.startFreshSelectedTab?() }
                .disabled(task?.startFreshSelectedTab == nil)
        }
    }
}
