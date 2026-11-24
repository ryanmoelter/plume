import SwiftData
import SwiftUI

/// The page the sidebar's Routines row opens: every routine, with its
/// schedule, its next and last run, and the controls to run, edit or delete it.
struct RoutinesView: View {
    let open: (_ taskID: UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared

    var body: some View {
        RoutinesContent(open: open)
            .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
            .foregroundStyle(ThemeChrome.foreground(for: colorScheme) ?? .primary)
            .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
            .navigationTitle("Routines")
    }
}

/// Which routine the editor sheet is open on. A new routine has no model yet.
private struct RoutineEditing: Identifiable {
    let id = UUID()
    let routine: Routine?
}

private struct RoutinesContent: View, ThemedView {
    let open: (UUID) -> Void
    @Environment(\.theme) var theme
    @Environment(\.modelContext) private var context
    @Query(sort: \Routine.orderIndex) private var routines: [Routine]
    @State private var editing: RoutineEditing?
    @State private var pendingDelete: Routine?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if routines.isEmpty {
                    Text("A routine starts a task from a prompt on a schedule. Runs land in the Routines group.")
                        .font(typography.body.font)
                        .emphasis(.secondary)
                        .plumeID(AccessibilityID.routinesEmptyState)
                } else {
                    ForEach(routines) { routine in
                        RoutineRow(routine: routine, open: open, edit: { editing = .init(routine: routine) }) {
                            pendingDelete = routine
                        }
                    }
                }
            }
            .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
            .padding(.horizontal, dimensions.horizontalEdgePadding)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .plumeID(AccessibilityID.routinesView)
        .sheet(item: $editing) { editing in
            RoutineEditor(routine: editing.routine) { draft in save(draft, to: editing.routine) }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "routine")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Routine", role: .destructive) {
                guard let routine = pendingDelete else { return }
                RoutineScheduler.shared.forget(routine.id)
                context.delete(routine)
                pendingDelete = nil
            }
        } message: {
            Text("Tasks it already started stay in the sidebar.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Routines")
                .font(typography.headline.font)
            Spacer()
            Button {
                editing = .init(routine: nil)
            } label: {
                Label("New Routine", systemImage: "plus")
            }
            .plumeID(AccessibilityID.routinesNewButton, invoke: { editing = .init(routine: nil) })
        }
    }

    private func save(_ draft: RoutineDraft, to existing: Routine?) {
        let routine = existing ?? {
            let routine = Routine(orderIndex: (routines.map(\.orderIndex).max() ?? -1) + 1)
            context.insert(routine)
            return routine
        }()
        draft.apply(to: routine)
    }
}

private struct RoutineRow: View, ThemedView {
    @Bindable var routine: Routine
    let open: (UUID) -> Void
    let edit: () -> Void
    let delete: () -> Void
    @Environment(\.theme) var theme
    @State private var scheduler = RoutineScheduler.shared

    var body: some View {
        let label = routine.name
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                    .font(typography.bodyLarge.font)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { routine.isEnabled }, set: { routine.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .plumeID(
                        AccessibilityID.routineEnabledToggle, label: label, value: routine.isEnabled ? "on" : "off",
                        invoke: { routine.setEnabled(!routine.isEnabled) }
                    )
            }
            Text(detailLine)
                .font(typography.caption.font)
                .emphasis(.secondary)
            Text(runLine)
                .font(typography.caption.font)
                .emphasis(.secondary)
            if let error = scheduler.lastRuns[routine.id]?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(typography.caption.font)
                    .foregroundStyle(colors.warning)
                    .plumeID(AccessibilityID.routineLastRunError, label: label, value: error)
            }
            HStack(spacing: 8) {
                Button("Run Now") { scheduler.runNow(routine) }
                    .plumeID(AccessibilityID.routineRunNowButton, label: label, invoke: { scheduler.runNow(routine) })
                    .disabled(scheduler.isStarting(routine.id))
                Button("Edit", action: edit)
                    .plumeID(AccessibilityID.routineEditButton, label: label, invoke: edit)
                if let taskID = scheduler.lastRuns[routine.id]?.taskID {
                    Button("Open Last Run") { open(taskID) }
                        .plumeID(AccessibilityID.routineOpenLastRunButton, label: label, invoke: { open(taskID) })
                }
                Spacer()
                Button("Delete", role: .destructive, action: delete)
                    .plumeID(AccessibilityID.routineDeleteButton, label: label, invoke: delete)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(colors.surfaceTint))
        .opacity(routine.isEnabled ? 1 : 0.7)
        .plumeID(AccessibilityID.routineRow, label: label, value: routine.isEnabled ? "enabled" : "disabled")
    }

    private var detailLine: String {
        let folder = (routine.folderPath as NSString).lastPathComponent
        let worktree = routine.runsInNewWorktree && routine.repoPath != nil ? " · new worktree" : ""
        return "\(routine.trigger.summary(calendar: .current)) · \(folder)\(worktree)"
    }

    private var runLine: String {
        var parts: [String] = []
        if scheduler.isStarting(routine.id) {
            parts.append("Starting…")
        } else if let next = routine.nextFireDate() {
            parts.append("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append(routine.isEnabled ? "No upcoming run" : "Off")
        }
        if let last = routine.lastRunAt {
            parts.append("Last run: \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}
