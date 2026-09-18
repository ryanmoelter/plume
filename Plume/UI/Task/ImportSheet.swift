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

    private var importable: [ImportCandidate] {
        (candidates ?? []).filter(\.isImportable)
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
                Button(importTitle) { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 580, height: 520)
        .task { await load() }
    }

    private var importTitle: String {
        selected.count == 1 ? "Import 1 Workspace" : "Import \(selected.count) Workspaces"
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

            Button("Select All") { selected = Set(importable.map(\.id)) }
                .disabled(selected.count == importable.count)
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
        if candidate.isAlreadyImported { return "Already imported" }
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
        selected = Set(importable.map(\.id))
    }

    private func runImport() {
        let chosen = (candidates ?? []).filter { selected.contains($0.id) }
        let created = Importer.importing(chosen, into: target, in: context)
        Importer.startWatches(for: created)
        dismiss()
    }
}
