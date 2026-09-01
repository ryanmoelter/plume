import SwiftUI

struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Actions the menu bar performs on the selected task. Nil when nothing is
/// selected, which disables the whole Task menu.
struct TaskCommands {
    let addTab: (TabKind) -> Void
    let selectTab: (Int) -> Void
    let cycleTab: (Int) -> Void
    let closeSelectedTab: () -> Void
}

struct TaskCommandsKey: FocusedValueKey {
    typealias Value = TaskCommands
}

extension FocusedValues {
    var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }

    var taskCommands: TaskCommands? {
        get { self[TaskCommandsKey.self] }
        set { self[TaskCommandsKey.self] = newValue }
    }
}

struct PlumeCommands: Commands {
    @FocusedValue(\.newTaskAction) private var newTask
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

        CommandGroup(after: .saveItem) {
            Button("Close Tab") { task?.closeSelectedTab() }
                .keyboardShortcut("w")
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
        }
    }
}
