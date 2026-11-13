#if DEBUG
import AppKit
import SwiftData

extension InProcessControlBackend {
    func tasks() throws -> TaskListResult {
        let selected = selectedTaskTitles()
        return TaskListResult(tasks: try windowTasks().map { task in
            let tab = focusedTab(of: task)
            return TaskDescription(
                id: task.id.uuidString,
                title: TitleStore.shared.displayTitle(for: task),
                isSelected: selected.contains(TitleStore.shared.displayTitle(for: task)),
                tabKind: tab?.kind.rawValue,
                expectsRows: tab.map(expectsRows) ?? false
            )
        })
    }

    func selectTask(_ params: SelectTaskParams) async throws -> SwitchLatencyReport {
        guard let window = CLICommandHandler.shared.frontmostWindow else { throw ControlError.noWindow }
        let all = try windowTasks()
        let candidates = all.map { (id: $0.id, title: TitleStore.shared.displayTitle(for: $0)) }
        let targetID = try TaskQuery.match(params.task, in: candidates)
        let fromID = try params.from.map { try TaskQuery.match($0, in: candidates) }
        guard let target = all.first(where: { $0.id == targetID }) else { throw ControlError.notFound(params.task) }
        if fromID == targetID { throw ControlError.badParams("task and from name the same task") }
        if fromID == nil, selectedTaskTitles().contains(TitleStore.shared.displayTitle(for: target)) {
            throw ControlError.badParams("\(params.task) is already selected; pass from")
        }
        let source = fromID.flatMap { id in all.first { $0.id == id } }

        // A driven instance is never frontmost, and App Nap would otherwise
        // throttle it into timings no user sees.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Measuring task switches"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var samples: [SwitchLatencyMeasurement] = []
        for _ in 0..<params.repeatCount {
            if let source {
                _ = await measureSwitch(to: source, in: window, timeout: params.timeout)
                try await Task.sleep(for: .seconds(params.settle))
            }
            samples.append(await measureSwitch(to: target, in: window, timeout: params.timeout))
            try await Task.sleep(for: .seconds(params.settle))
        }
        return SwitchLatencyReport(samples: samples)
    }

    private func measureSwitch(
        to task: WorkTask, in window: CLICommandHandler.WindowRegistration, timeout: Double
    ) async -> SwitchLatencyMeasurement {
        let tab = focusedTab(of: task)
        return await withCheckedContinuation { continuation in
            SwitchLatencyProbe.begin(
                TitleStore.shared.displayTitle(for: task),
                tabID: tab?.id,
                expectsRows: tab.map(expectsRows) ?? false,
                timeout: timeout
            ) { continuation.resume(returning: $0) }
            SwitchLatencyProbe.time("reveal") { window.reveal(task.id) }
        }
    }

    private func windowTasks() throws -> [WorkTask] {
        guard let window = CLICommandHandler.shared.frontmostWindow else { throw ControlError.noWindow }
        let descriptor = FetchDescriptor<WorkTask>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.orderIndex)]
        )
        return try window.context.fetch(descriptor)
    }

    /// The selected sidebar row registers `value: "selected"`, labelled with the
    /// task's display title.
    private func selectedTaskTitles() -> Set<String> {
        Set(ControlRegistry.shared.entries(id: AccessibilityID.taskRow)
            .filter { $0.entry.value == "selected" }
            .compactMap(\.entry.label))
    }

    private func focusedTab(of task: WorkTask) -> TaskTab? {
        task.orderedTabs.first { $0.id == task.selectedTabID } ?? task.orderedTabs.first
    }

    private func expectsRows(_ tab: TaskTab) -> Bool {
        tab.kind == .agent && (tab.sessionJSONLPath != nil || tab.agentSessionID != nil)
    }
}
#endif
