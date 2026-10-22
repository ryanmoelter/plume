import SwiftUI
import SwiftData

/// Picks which workspaces to bring into Plume, grouped the way the source
/// app groups them so the list reads as the sidebar it is about to create.
struct ImportSheet: View {
    let source: ImportSource

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TaskGroup.orderIndex) private var groups: [TaskGroup]

    /// Nil while the file is being read.
    @State private var candidates: [ImportCandidate]?
    @State private var emptyStateText = ""
    @State private var sourceIsRunning = false
    @State private var alert: ImportAlert?
    @State private var selected: Set<String> = []
    @State private var target: ImportTarget = .mirrorSourceGroups
    @State private var isValidating = true

    private var importable: [ImportCandidate] {
        (candidates ?? []).filter(\.isImportable)
    }

    /// What Import selects on its own: never a replacement, which destroys a
    /// task the user may still want.
    private var selectableByDefault: [ImportCandidate] {
        importable.filter { !$0.replacesExistingTask }
    }

    private var chosen: [ImportCandidate] {
        (candidates ?? []).filter { selected.contains($0.id) }
    }

    private var replacements: [ImportCandidate] {
        chosen.filter(\.replacesExistingTask)
    }

    private var canImport: Bool { !selected.isEmpty && !isValidating }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from \(source.displayName)").font(.headline)

            if sourceIsRunning, let warning = source.runningWarning {
                runningBanner(warning)
            }

            if let candidates {
                if candidates.isEmpty {
                    emptyState
                } else {
                    controls
                    list(candidates)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                if isValidating, candidates?.isEmpty == false {
                    ProgressView().controlSize(.small)
                    Text("Checking workspaces…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .plumeID(AccessibilityID.importCancelButton)
                Button(importTitle) { confirmOrImport() }
                    .keyboardShortcut(.defaultAction)
                    .plumeID(AccessibilityID.importConfirmButton, value: importTitle)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 580, height: 520)
        .task { await load() }
        .alert(
            alertTitle,
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
            presenting: alert
        ) { alert in
            switch alert {
            case .confirmReplacement:
                Button("Cancel", role: .cancel) {}
                Button("Replace", role: .destructive) {
                    // Deferred so the alert's own dismissal cannot clear the reminder.
                    Task { @MainActor in runImport() }
                }
            case .postImportReminder:
                Button("OK") { dismiss() }
            }
        } message: { alert in
            Text(alertMessage(for: alert))
        }
    }

    private var alertTitle: String {
        switch alert {
        case .confirmReplacement(let live):
            "Replace running \(live.count == 1 ? "task" : "tasks")?"
        case .postImportReminder:
            "Quit \(source.displayName)"
        case nil:
            ""
        }
    }

    private func alertMessage(for alert: ImportAlert) -> String {
        switch alert {
        case .confirmReplacement(let live): replacementWarning(for: live)
        case .postImportReminder: source.postImportReminder ?? ""
        }
    }

    private func runningBanner(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .plumeID(AccessibilityID.importRunningWarning, value: warning)
    }

    private func replacementWarning(for live: [ImportCandidate]) -> String {
        let names = live.map(\.title).joined(separator: ", ")
        let subject = live.count == 1
            ? "\(names) has a running agent or terminal"
            : "\(names) have running agents or terminals"
        return "\(subject). Replacing stops them and discards the existing \(live.count == 1 ? "task" : "tasks")."
    }

    private var importTitle: String {
        let noun = selected.count == 1 ? "Workspace" : "Workspaces"
        guard replacements.isEmpty else {
            return "Import \(selected.count) \(noun) (\(replacements.count) replacing)"
        }
        return "Import \(selected.count) \(noun)"
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing to Import",
            systemImage: "tray",
            description: Text(emptyStateText)
        )
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        HStack {
            Picker("Add to", selection: $target) {
                Text(source.groupMirrorLabel).tag(ImportTarget.mirrorSourceGroups)
                Text("Ungrouped").tag(ImportTarget.ungrouped)
                ForEach(groups) { group in
                    Text(group.name).tag(ImportTarget.existing(group.id))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            Button("Select All") { selected = Set(selectableByDefault.map(\.id)) }
                .plumeID(AccessibilityID.importSelectAllButton)
                .disabled(selected == Set(selectableByDefault.map(\.id)))
            Button("Select None") { selected = [] }
                .plumeID(AccessibilityID.importSelectNoneButton)
                .disabled(selected.isEmpty)
        }
        .buttonStyle(.link)
    }

    private func list(_ candidates: [ImportCandidate]) -> some View {
        List {
            ForEach(sections(of: candidates), id: \.name) { section in
                Section(section.name) {
                    ForEach(section.candidates) { candidate in
                        row(candidate)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }

    private func row(_ candidate: ImportCandidate) -> some View {
        let isOn = binding(for: candidate)
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.title).lineLimit(1)
                    if candidate.workspace.kind == .worktree, let branch = candidate.workspace.branchName {
                        Label(branch, systemImage: "tree")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Head-truncated: sibling worktrees differ only in their last
                // component, which tail truncation would hide.
                Text(abbreviatedPath(candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(subtitle(for: candidate))
                    .font(.caption)
                    .foregroundStyle(candidate.isImportable ? Color.secondary : Color.orange)
            }
        }
        .plumeID(
            AccessibilityID.importRow,
            label: "\(candidate.title) — \(abbreviatedPath(candidate))",
            value: "\(isOn.wrappedValue ? "on" : "off") · \(subtitle(for: candidate))",
            invoke: { isOn.wrappedValue.toggle() }
        )
        .disabled(!candidate.isImportable)
    }

    private func abbreviatedPath(_ candidate: ImportCandidate) -> String {
        candidate.workingDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func subtitle(for candidate: ImportCandidate) -> String {
        if candidate.isAlreadyImported { return "Already imported — check to replace" }
        if let rejection = candidate.rejection { return rejection.reason }
        var parts: [String] = []
        if candidate.agentTabCount > 0 {
            parts.append(candidate.agentTabCount == 1 ? "1 agent" : "\(candidate.agentTabCount) agents")
        }
        if candidate.terminalTabCount > 0 {
            parts.append(candidate.terminalTabCount == 1 ? "1 terminal" : "\(candidate.terminalTabCount) terminals")
        }
        return parts.joined(separator: " · ")
    }

    private func binding(for candidate: ImportCandidate) -> Binding<Bool> {
        Binding(
            get: { selected.contains(candidate.id) },
            set: { isOn in
                if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
            }
        )
    }

    private func sections(of candidates: [ImportCandidate]) -> [(name: String, candidates: [ImportCandidate])] {
        var order: [String] = []
        var grouped: [String: [ImportCandidate]] = [:]
        for candidate in candidates {
            let name = candidate.groupName ?? "Ungrouped"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(candidate)
        }
        return order.map { (name: $0, candidates: grouped[$0] ?? []) }
    }

    /// Two phases: the file is decoded and mapped synchronously so rows appear
    /// at once, then each row is replaced as git and the transcripts answer.
    private func load() async {
        let loaded = await source.loadCandidates()
        emptyStateText = loaded.emptyStateText
        sourceIsRunning = loaded.sourceIsRunning
        let built = Importer.marking(
            loaded.candidates,
            alreadyImported: Importer.alreadyImported(in: context)
        )
        candidates = built
        guard !built.isEmpty else {
            isValidating = false
            return
        }

        let validator = source.makeValidator()
        for candidate in built {
            let validated = await validator.validating(candidate)
            guard let index = candidates?.firstIndex(where: { $0.id == validated.id }) else { continue }
            var marked = validated
            marked.isAlreadyImported = candidates?[index].isAlreadyImported ?? false
            candidates?[index] = marked
        }
        isValidating = false
        selected = Set(selectableByDefault.map(\.id))
    }

    /// Replacing a task whose agent or terminal is still running kills it
    /// mid-turn, which the checkbox alone does not convey.
    private func confirmOrImport() {
        let live = replacements.filter { Importer.hasLiveSession(stableID: $0.stableID, in: context) }
        if live.isEmpty {
            runImport()
        } else {
            alert = .confirmReplacement(live)
        }
    }

    private func runImport() {
        let created = Importer.importing(chosen, into: target, in: context)
        Importer.startWatches(for: created)
        if sourceIsRunning, !created.isEmpty, source.postImportReminder != nil {
            alert = .postImportReminder
        } else {
            dismiss()
        }
    }
}

private enum ImportAlert {
    case confirmReplacement([ImportCandidate])
    case postImportReminder
}
