import AppKit
import SwiftUI

struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ShowArchiveActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ShowImportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Moves the sidebar selection by `offset` tasks, following sidebar order.
/// Unlike `TaskCommands`, this stays available with nothing selected, so it
/// can select the first task the same way an arrow key does.
struct SelectAdjacentTaskKey: FocusedValueKey {
    typealias Value = (Int) -> Void
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

    var showImportAction: (() -> Void)? {
        get { self[ShowImportActionKey.self] }
        set { self[ShowImportActionKey.self] = newValue }
    }

    var selectAdjacentTask: ((Int) -> Void)? {
        get { self[SelectAdjacentTaskKey.self] }
        set { self[SelectAdjacentTaskKey.self] = newValue }
    }

    var taskCommands: TaskCommands? {
        get { self[TaskCommandsKey.self] }
        set { self[TaskCommandsKey.self] = newValue }
    }
}

/// Every keyboard shortcut `PlumeCommands` binds, in one place.
///
/// The menu items below take their chords from here, and
/// `TerminalShortcutMonitor` claims these same chords back when a terminal
/// surface holds focus. Adding a shortcut means adding it here and using it in
/// the button — there is no second list to update.
enum PlumeShortcuts {
    static let newTask = MenuShortcut("n")
    static let newTerminalTab = MenuShortcut("t")
    static let newAgentTab = MenuShortcut("t", modifiers: [.command, .option])
    static let showArchive = MenuShortcut("a", modifiers: [.command, .shift])
    static let closeTab = MenuShortcut("w")
    static let archiveTask = MenuShortcut("a", modifiers: [.command, .control])
    /// ⌘1 through ⌘9, selecting a tab by position.
    static let selectTab: [MenuShortcut] = (1...9).map { MenuShortcut(Character("\($0)")) }

    private static let fixed: [MenuShortcut] = [
        newTask, newTerminalTab, newAgentTab, showArchive, closeTab, archiveTask,
    ] + selectTab

    static var all: [MenuShortcut] {
        all(with: AppSettings.shared.shortcutBindings)
    }

    static func all(with bindings: ShortcutBindings) -> [MenuShortcut] {
        fixed + bindings.all
    }
}

struct PlumeCommands: Commands {
    @FocusedValue(\.newTaskAction) private var newTask
    @FocusedValue(\.showArchiveAction) private var showArchive
    @FocusedValue(\.showImportAction) private var showImport
    @FocusedValue(\.taskCommands) private var task
    @FocusedValue(\.selectAdjacentTask) private var selectAdjacentTask

    /// The chord this menu is *built* with. SwiftUI never re-evaluates a
    /// `Commands` body for a changed binding, so `ShortcutMenuApplier` writes
    /// later rebinds straight onto the built item.
    private func shortcut(for action: ShortcutAction) -> MenuShortcut? {
        AppSettings.shared.shortcutBindings[action]
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { newTask?() }
                .keyboardShortcut(PlumeShortcuts.newTask)
                .disabled(newTask == nil)

            Button("New Terminal Tab") { task?.addTab(.terminal) }
                .keyboardShortcut(PlumeShortcuts.newTerminalTab)
                .disabled(task == nil)

            Button("New Chat Tab") { task?.addTab(.agent) }
                .keyboardShortcut(PlumeShortcuts.newAgentTab)
                .disabled(task == nil)
        }

        CommandGroup(after: .importExport) {
            Button("Import from cmux…") { showImport?() }
                .disabled(showImport == nil)
        }

        // No `@FocusedValue`/`disabled`: a `Commands` body never re-evaluates
        // for a changed `@Observable`, so a stale enabled state would stick.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
        }

        CommandGroup(after: .toolbar) {
            Button("Show Archive…") { showArchive?() }
                .keyboardShortcut(PlumeShortcuts.showArchive)
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
            .keyboardShortcut(PlumeShortcuts.closeTab)

            Button("Archive Task") { task?.archiveSelectedTask() }
                .keyboardShortcut(PlumeShortcuts.archiveTask)
                .disabled(task == nil)
        }

        CommandMenu("Tab") {
            Button("Next Tab") { task?.cycleTab(1) }
                .keyboardShortcut(shortcut(for: .nextTab))
                .disabled(task == nil)
            Button("Previous Tab") { task?.cycleTab(-1) }
                .keyboardShortcut(shortcut(for: .previousTab))
                .disabled(task == nil)

            Divider()

            Button("Next Task") { selectAdjacentTask?(1) }
                .keyboardShortcut(shortcut(for: .nextTask))
                .disabled(selectAdjacentTask == nil)
            Button("Previous Task") { selectAdjacentTask?(-1) }
                .keyboardShortcut(shortcut(for: .previousTask))
                .disabled(selectAdjacentTask == nil)

            Divider()

            ForEach(Array(PlumeShortcuts.selectTab.enumerated()), id: \.offset) { index, shortcut in
                Button("Tab \(index + 1)") { task?.selectTab(index) }
                    .keyboardShortcut(shortcut)
                    .disabled(task == nil)
            }

            Divider()

            Button("Start Fresh Conversation…") { task?.startFreshSelectedTab?() }
                .disabled(task?.startFreshSelectedTab == nil)
        }
    }
}
