import SwiftUI
import SwiftData

/// Picks which cmux workspaces to bring into Plume, grouped the way cmux
/// groups them so the list reads as the sidebar it is about to create.
struct ImportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TaskGroup.orderIndex) private var groups: [TaskGroup]

    /// Nil while the file is being read.
    @State private var candidates: [ImportCandidate]?
    @State private var selected: Set<String> = []
    @State private var target: ImportTarget = .mirrorSourceGroups
    @State private var isValidating = true
    @State private var confirmingReplacementOf: [ImportCandidate] = []

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
            Text("Import from cmux").font(.headline)

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
                Button(importTitle) { confirmOrImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 580, height: 520)
        .task { await load() }
        .alert(
            "Replace running \(confirmingReplacementOf.count == 1 ? "task" : "tasks")?",
            isPresented: Binding(
                get: { !confirmingReplacementOf.isEmpty },
                set: { if !$0 { confirmingReplacementOf = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmingReplacementOf = [] }
            Button("Replace", role: .destructive) {
                confirmingReplacementOf = []
                runImport()
            }
        } message: {
            Text(replacementWarning)
        }
    }

    private var replacementWarning: String {
        let names = confirmingReplacementOf.map(\.title).joined(separator: ", ")
        let subject = confirmingReplacementOf.count == 1
            ? "\(names) has a running agent or terminal"
            : "\(names) have running agents or terminals"
        return "\(subject). Replacing stops them and discards the existing \(confirmingReplacementOf.count == 1 ? "task" : "tasks")."
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
            description: Text(CmuxLocations.isInstalled()
                ? "cmux has no saved workspaces."
                : "No cmux session file at \(CmuxLocations.sessionFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        )
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        HStack {
            Picker("Add to", selection: $target) {
                Text("Mirror cmux groups").tag(ImportTarget.mirrorSourceGroups)
                Text("Ungrouped").tag(ImportTarget.ungrouped)
                ForEach(groups) { group in
                    Text(group.name).tag(ImportTarget.existing(group.id))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            Button("Select All") { selected = Set(selectableByDefault.map(\.id)) }
                .disabled(selected == Set(selectableByDefault.map(\.id)))
            Button("Select None") { selected = [] }
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
        Toggle(isOn: binding(for: candidate)) {
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
                Text(candidate.workingDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(subtitle(for: candidate))
                    .font(.caption)
                    .foregroundStyle(candidate.isImportable ? Color.secondary : Color.orange)
            }
        }
        .disabled(!candidate.isImportable)
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
        let snapshot = await Task.detached { CmuxSnapshot.loadingFromDisk() }.value
        let built = Importer.marking(
            CmuxCandidateBuilder.candidates(from: snapshot),
            alreadyImported: Importer.alreadyImported(in: context)
        )
        candidates = built
        guard !built.isEmpty else {
            isValidating = false
            return
        }

        for candidate in built {
            let validated = await CmuxImportValidator.validating(candidate)
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
            confirmingReplacementOf = live
        }
    }

    private func runImport() {
        let created = Importer.importing(chosen, into: target, in: context)
        Importer.startWatches(for: created)
        dismiss()
    }
}
