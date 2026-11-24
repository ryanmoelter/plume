import AppKit
import SwiftUI

/// The sheet that creates or edits a routine. Nothing reaches the model until
/// Save.
struct RoutineEditor: View, ThemedView {
    let onSave: (RoutineDraft) -> Void
    @Environment(\.theme) var theme
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoutineDraft
    @State private var isTrusted = true
    @State private var settings = AppSettings.shared
    /// The composer's model, effort and permission controls write to a tab
    /// before launch, so they edit this one, which is never inserted.
    @State private var scratchTask: WorkTask
    @State private var scratchTab: TaskTab
    private let isNew: Bool

    init(routine: Routine?, onSave: @escaping (RoutineDraft) -> Void) {
        let draft = routine.map(RoutineDraft.init) ?? RoutineDraft(folderPath: RecentFolders.mostRecent() ?? "")
        let task = WorkTask(title: "Routine", orderIndex: 0)
        let tab = TaskTab(kind: .agent, orderIndex: 0, task: task)
        draft.choices.apply(to: tab)
        tab.transport = .headless
        tab.workingDirectoryPath = draft.folderPath.isEmpty ? nil : draft.folderPath
        self.onSave = onSave
        self.isNew = routine == nil
        _draft = State(initialValue: draft)
        _scratchTask = State(initialValue: task)
        _scratchTab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .plumeID(AccessibilityID.routineEditorName, value: draft.name, setValue: { draft.name = $0 })
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                        TextEditor(text: $draft.prompt)
                            .font(.body)
                            .frame(minHeight: 90)
                            .plumeID(AccessibilityID.routineEditorPrompt, value: draft.prompt, setValue: { draft.prompt = $0 })
                    }
                }
                Section("Where") {
                    folderPicker
                    if !isTrusted, scratchTab.provider == .claudeCode {
                        Label(
                            "Claude Code hasn't been trusted in this folder, so runs will fail. Open it in a terminal tab and accept the trust prompt first.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(colors.warning)
                        .plumeID(AccessibilityID.routineEditorUntrustedWarning)
                    }
                    if draft.repoPath != nil {
                        Toggle("New worktree for each run", isOn: $draft.runsInNewWorktree)
                            .plumeID(
                                AccessibilityID.routineEditorWorktreeToggle,
                                value: draft.runsInNewWorktree ? "on" : "off",
                                invoke: { draft.runsInNewWorktree.toggle() }
                            )
                    }
                }
                Section("Agent") {
                    ComposerControlsRow(task: scratchTask, tab: scratchTab, headlessSession: nil)
                }
                Section("Schedule") {
                    scheduleEditor
                    Toggle("Notify when a run finishes", isOn: $draft.notifiesOnFinish)
                        .plumeID(
                            AccessibilityID.routineEditorNotifyToggle,
                            value: draft.notifiesOnFinish ? "on" : "off",
                            invoke: { draft.notifiesOnFinish.toggle() }
                        )
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 560)
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .task(id: draft.folderPath) { await resolveFolder() }
        .plumeID(AccessibilityID.routineEditorSheet)
    }

    private var folderPicker: some View {
        let folders = RecentFolders.load().filter { FileManager.default.fileExists(atPath: $0) }
        return LabeledContent("Folder") {
            Menu(draft.folderPath.isEmpty ? "Choose…" : (draft.folderPath as NSString).lastPathComponent) {
                ForEach(folders, id: \.self) { folder in
                    Button(folder) { setFolder(folder) }
                }
                if !folders.isEmpty { Divider() }
                Button("Choose Folder…", action: chooseFolder)
                    .plumeID(AccessibilityID.routineEditorChooseFolderButton, invoke: chooseFolder)
            }
            .fixedSize()
            .help(draft.folderPath)
            .plumeID(
                AccessibilityID.routineEditorFolderMenu,
                value: draft.folderPath,
                setValue: { setFolder(($0 as NSString).expandingTildeInPath) }
            )
        }
    }

    @ViewBuilder
    private var scheduleEditor: some View {
        Picker("Repeat", selection: $draft.triggerKind) {
            Text("Every N hours").tag(RoutineTriggerKind.interval)
            Text("Weekly").tag(RoutineTriggerKind.weekly)
            Text("Once").tag(RoutineTriggerKind.once)
        }
        .pickerStyle(.segmented)
        .plumeID(
            AccessibilityID.routineEditorTriggerKind,
            value: draft.triggerKind.rawValue,
            setValue: { if let kind = RoutineTriggerKind(rawValue: $0) { draft.triggerKind = kind } }
        )
        switch draft.triggerKind {
        case .interval:
            Stepper(value: $draft.intervalHours, in: 1...168) {
                Text(draft.intervalHours == 1 ? "Every hour" : "Every \(draft.intervalHours) hours")
            }
            .plumeID(
                AccessibilityID.routineEditorIntervalHours,
                value: String(draft.intervalHours),
                setValue: { if let hours = Int($0), hours >= 1 { draft.intervalHours = hours } }
            )
        case .weekly:
            LabeledContent("Days") {
                HStack(spacing: 4) {
                    ForEach(RoutineTrigger.orderedWeekdays(calendar: .current), id: \.self) { weekday in
                        weekdayToggle(weekday)
                    }
                }
            }
            DatePicker("Time", selection: weeklyTime, displayedComponents: .hourAndMinute)
                .plumeID(
                    AccessibilityID.routineEditorTime,
                    value: RoutineTrigger.timeText(minuteOfDay: draft.minuteOfDay, calendar: .current),
                    setValue: { text in if let minutes = Self.minuteOfDay(parsing: text) { draft.minuteOfDay = minutes } }
                )
        case .once:
            DatePicker("Date", selection: $draft.onceDate, in: Date()...)
                .plumeID(
                    AccessibilityID.routineEditorOnceDate,
                    value: draft.onceDate.ISO8601Format(),
                    setValue: { if let date = try? Date($0, strategy: .iso8601) { draft.onceDate = date } }
                )
        }
    }

    private func weekdayToggle(_ weekday: Int) -> some View {
        let day = RoutineWeekdays(weekday: weekday)
        let symbol = Calendar.current.veryShortWeekdaySymbols[weekday - 1]
        let name = Calendar.current.shortWeekdaySymbols[weekday - 1]
        let isOn = Binding(
            get: { draft.weekdays.contains(day) },
            set: { if $0 { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }
        )
        return Toggle(symbol, isOn: isOn)
            .toggleStyle(.button)
            .help(name)
            .plumeID(
                AccessibilityID.routineEditorWeekday, label: name, value: isOn.wrappedValue ? "on" : "off",
                invoke: { isOn.wrappedValue.toggle() }
            )
    }

    private var footer: some View {
        let problem = draft.problem(now: Date())
        return HStack {
            if let problem {
                Text(problem)
                    .font(typography.caption.font)
                    .emphasis(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .plumeID(AccessibilityID.routineEditorCancelButton, invoke: { dismiss() })
            Button(isNew ? "Create" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .plumeID(AccessibilityID.routineEditorSaveButton, invoke: save)
                .disabled(problem != nil)
        }
        .padding(16)
    }

    private var weeklyTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: draft.minuteOfDay / 60, minute: draft.minuteOfDay % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    /// `HH:mm`, for a driver setting the time without the picker.
    static func minuteOfDay(parsing text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private func setFolder(_ path: String) {
        guard path != draft.folderPath else { return }
        draft.folderPath = path
        draft.repoPath = nil
        scratchTab.workingDirectoryPath = path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url.path)
    }

    private func resolveFolder() async {
        let path = draft.folderPath
        guard !path.isEmpty else {
            isTrusted = true
            return
        }
        let (trusted, repository) = await Task.detached(priority: .userInitiated) {
            (ClaudeTrustStore.isTrusted(path), ProjectRoot.containing(path).map(ProjectRoot.repositoryDirectory(forRoot:)))
        }.value
        guard path == draft.folderPath else { return }
        isTrusted = trusted
        draft.repoPath = repository
        if repository == nil { draft.runsInNewWorktree = false }
    }

    private func save() {
        guard draft.problem(now: Date()) == nil else { return }
        var draft = draft
        draft.choices = TabLaunchChoices(scratchTab)
        draft.choices.transportRaw = AgentTransport.headless.rawValue
        onSave(draft)
        dismiss()
    }
}
