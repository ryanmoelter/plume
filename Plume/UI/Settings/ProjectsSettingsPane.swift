import AppKit
import SwiftData
import SwiftUI

/// Per-repository settings for `plume wt`, over a defaults row. Projects come
/// from the tasks' repositories plus any added by hand. An unset field shows
/// what it falls back to.
struct ProjectsSettingsPane: View {
    enum Scope: Hashable {
        case defaults
        case project(String)

        var root: String? {
            if case .project(let root) = self { return root }
            return nil
        }
    }

    @State private var settings = AppSettings.shared
    @Query private var tasks: [WorkTask]
    @State private var discoveredRoots: [String] = []
    @State private var scope: Scope = .defaults
    @State private var fallbacks = ProjectFallbacks.unloaded
    @State private var addError: String?

    private var configuration: ProjectsConfiguration { settings.projectsConfiguration }

    private var projectRoots: [String] {
        Set(discoveredRoots).union(configuration.repositories.keys).sorted {
            let left = ($0 as NSString).lastPathComponent.lowercased()
            let right = ($1 as NSString).lastPathComponent.lowercased()
            return (left, $0) < (right, $1)
        }
    }

    private var repoPaths: [String] {
        Array(Set(tasks.compactMap(\.repoPath))).sorted()
    }

    private var current: ProjectSettings {
        guard let root = scope.root else { return configuration.defaults }
        return configuration.repositories[root] ?? ProjectSettings()
    }

    /// What a nil field means in this scope: the defaults row for a project,
    /// then git.
    private var inherited: ProjectSettings {
        let derived = ProjectSettings(
            baseBranch: fallbacks.baseBranch,
            branchPrefix: fallbacks.branchPrefix,
            forge: fallbacks.forge,
            nerdFont: false,
            protectedWorktrees: [],
            ignoredPendingChecks: []
        )
        return scope.root == nil ? derived : configuration.defaults.overriding(derived)
    }

    private func update(_ change: (inout ProjectSettings) -> Void) {
        var configuration = settings.projectsConfiguration
        if let root = scope.root {
            var project = configuration.repositories[root] ?? ProjectSettings()
            change(&project)
            configuration.repositories[root] = project
        } else {
            change(&configuration.defaults)
        }
        settings.projectsConfiguration = configuration
    }

    var body: some View {
        Form {
            Section {
                projectList
            } header: {
                Text("Projects")
            } footer: {
                Text("Read by `plume wt`. A project's setting wins over Defaults; anything left empty falls back to what git says.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ProjectSettingsFields(settings: current, inherited: inherited, isDefaults: scope == .defaults, update: update)
            } header: {
                Text(scope.root.map { ($0 as NSString).lastPathComponent } ?? "Defaults")
            }
        }
        .formStyle(.grouped)
        .task(id: repoPaths) {
            let paths = repoPaths
            let roots = await Task.detached { Set(paths.compactMap(ProjectRoot.containing)) }.value
            // The detached work outlives cancellation, so a superseded scan
            // would otherwise overwrite a newer one.
            guard !Task.isCancelled, paths == repoPaths else { return }
            discoveredRoots = Array(roots)
        }
        .task(id: scope) {
            let root = scope.root
            let loaded = await Task.detached { ProjectFallbacks.load(root: root) }.value
            guard !Task.isCancelled, root == scope.root else { return }
            fallbacks = loaded
        }
    }

    @ViewBuilder
    private var projectList: some View {
        projectRow(.defaults, title: "Defaults", subtitle: "Every project unless it sets its own")
        ForEach(projectRoots, id: \.self) { root in
            projectRow(
                .project(root),
                title: (root as NSString).lastPathComponent,
                subtitle: (root as NSString).abbreviatingWithTildeInPath
            )
        }
        HStack {
            if let addError {
                Text(addError)
                    .foregroundStyle(.red)
            }
            Spacer()
            if let root = scope.root, configuration.repositories[root] != nil {
                let title = discoveredRoots.contains(root) ? "Reset" : "Remove"
                Button(title) { remove(root) }
                    .plumeID(AccessibilityID.settingsProjectRemoveButton, label: title, invoke: { remove(root) })
            }
            Button("Add Project…", action: addProject)
                .plumeID(AccessibilityID.settingsProjectAddButton, invoke: addProject)
        }
    }

    private func projectRow(_ rowScope: Scope, title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if scope == rowScope {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { scope = rowScope }
        .plumeID(
            AccessibilityID.settingsProjectRow,
            label: rowScope.root ?? "defaults",
            value: scope == rowScope ? "selected" : nil,
            invoke: { scope = rowScope }
        )
    }

    private func remove(_ root: String) {
        settings.projectsConfiguration.repositories[root] = nil
        if !discoveredRoots.contains(root) { scope = .defaults }
    }

    private func addProject() {
        addError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        Task {
            guard let root = await Task.detached(operation: { ProjectRoot.containing(path) }).value else {
                addError = "\((path as NSString).lastPathComponent) is not a git repository"
                return
            }
            if settings.projectsConfiguration.repositories[root] == nil {
                settings.projectsConfiguration.repositories[root] = ProjectSettings()
            }
            scope = .project(root)
        }
    }
}

/// One scope's fields. A nil field shows `inherited` as its placeholder.
private struct ProjectSettingsFields: View {
    let settings: ProjectSettings
    let inherited: ProjectSettings
    /// The defaults row has no repository to read an origin from.
    let isDefaults: Bool
    let update: ((inout ProjectSettings) -> Void) -> Void

    var body: some View {
        TextField("Base branch", text: text(\.baseBranch), prompt: Text(isDefaults ? "origin's default branch, else main" : inherited.baseBranch ?? "main"))
            .plumeID(AccessibilityID.settingsProjectField, label: "baseBranch", value: settings.baseBranch ?? "", setValue: { value in
                update { $0.baseBranch = value.isEmpty ? nil : value }
            })

        LabeledContent("Branch prefix") {
            HStack {
                TextField("Branch prefix", text: text(\.branchPrefix), prompt: Text(prefixPlaceholder))
                    .labelsHidden()
                    .onSubmit(normalizePrefix)
                    .plumeID(AccessibilityID.settingsProjectField, label: "branchPrefix", value: settings.branchPrefix ?? "", setValue: { value in
                        update { $0.branchPrefix = value.isEmpty ? nil : value }
                        normalizePrefix()
                    })
                    .disabled(settings.branchPrefix == "")
                Toggle("No prefix", isOn: noPrefix)
                    .plumeID(AccessibilityID.settingsProjectNoPrefixToggle, value: settings.branchPrefix == "" ? "on" : "off", invoke: {
                        noPrefix.wrappedValue.toggle()
                    })
            }
        }

        Picker("Forge", selection: Binding(get: { settings.forge }, set: { value in update { $0.forge = value } })) {
            Text(isDefaults ? "Automatic (from the origin URL)" : "Automatic (\(Self.name(inherited.forge ?? .none)))").tag(ForgeKind?.none)
            ForEach([ForgeKind.github, .gitlab, .none], id: \.self) { kind in
                Text(Self.name(kind)).tag(ForgeKind?.some(kind))
            }
        }
        .plumeID(AccessibilityID.settingsProjectForgePicker, value: settings.forge?.rawValue ?? "auto")

        Picker("Nerd Font icons", selection: Binding(get: { settings.nerdFont }, set: { value in update { $0.nerdFont = value } })) {
            Text("Default (\(inherited.nerdFont == true ? "on" : "off"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .plumeID(AccessibilityID.settingsProjectNerdFontPicker, value: settings.nerdFont.map { $0 ? "on" : "off" } ?? "default")

        NameListEditor(
            title: "Protected worktrees",
            prompt: "Worktree folder name",
            names: settings.protectedWorktrees,
            inherited: inherited.protectedWorktrees ?? [],
            set: { names in update { $0.protectedWorktrees = names } }
        )
        NameListEditor(
            title: "Ignored pending checks",
            prompt: "Check name",
            names: settings.ignoredPendingChecks,
            inherited: inherited.ignoredPendingChecks ?? [],
            set: { names in update { $0.ignoredPendingChecks = names } }
        )
    }

    private var prefixPlaceholder: String {
        switch inherited.branchPrefix {
        case nil: "None (no user.email)"
        case "": "No prefix"
        case let prefix?: WTSettings.normalizedBranchPrefix(prefix)
        }
    }

    /// Applied on submit rather than per keystroke, which would add the `/`
    /// mid-word. Resolution normalizes too, so a field left unsubmitted
    /// still resolves the same.
    private func normalizePrefix() {
        update { settings in
            guard let prefix = settings.branchPrefix, !prefix.isEmpty else { return }
            let normalized = WTSettings.normalizedBranchPrefix(prefix)
            settings.branchPrefix = normalized.isEmpty ? nil : normalized
        }
    }

    private var noPrefix: Binding<Bool> {
        Binding(
            get: { settings.branchPrefix == "" },
            set: { isOn in update { $0.branchPrefix = isOn ? "" : nil } }
        )
    }

    /// An empty field stores nil, so the fallback applies.
    private func text(_ keyPath: WritableKeyPath<ProjectSettings, String?>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] ?? "" },
            set: { value in update { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }

    private static func name(_ kind: ForgeKind) -> String {
        switch kind {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .none: "None"
        }
    }
}

/// A list setting. Nil inherits; once edited, the list replaces the
/// inherited one, even when emptied, until "Use Default" clears it.
private struct NameListEditor: View {
    let title: String
    let prompt: String
    let names: [String]?
    let inherited: [String]
    let set: ([String]?) -> Void
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing) {
                if let names {
                    ForEach(names, id: \.self) { name in
                        HStack {
                            Text(name)
                            Button {
                                set(names.filter { $0 != name })
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .plumeID(AccessibilityID.settingsProjectListRemoveButton, label: "\(title): \(name)", invoke: {
                                set(names.filter { $0 != name })
                            })
                        }
                    }
                    if names.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    Button("Use Default") { set(nil) }
                        .buttonStyle(.link)
                } else {
                    Text(inherited.isEmpty ? "Default: none" : "Default: \(inherited.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField(title, text: $draft, prompt: Text(prompt))
                        .labelsHidden()
                        .onSubmit(add)
                        .plumeID(AccessibilityID.settingsProjectField, label: title, value: draft, setValue: { draft = $0 })
                    Button("Add", action: add)
                        .plumeID(AccessibilityID.settingsProjectListAddButton, label: title, invoke: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Comma-separated input adds several. A first edit starts from the
    /// inherited list rather than replacing it with one name.
    private func add() {
        var updated = names ?? inherited
        for name in draft.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if !updated.contains(name) { updated.append(name) }
        }
        draft = ""
        set(updated)
    }
}
