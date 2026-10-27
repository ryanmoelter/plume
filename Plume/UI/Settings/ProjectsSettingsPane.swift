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
            nerdFont: .automatic,
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

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 2) {
            projectRow(.defaults, title: "Defaults", subtitle: "Every project unless it sets its own")
            ForEach(projectRoots, id: \.self) { root in
                projectRow(
                    .project(root),
                    title: (root as NSString).lastPathComponent,
                    subtitle: (root as NSString).abbreviatingWithTildeInPath
                )
            }
            Button(action: addProject) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").frame(width: Self.leadingIconWidth)
                    Text("Add Project…")
                }
                .padding(.horizontal, Self.rowPadding)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Self.accent)
            .plumeID(AccessibilityID.settingsProjectAddButton, invoke: addProject)
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Self.rowPadding)
            }
        }
    }

    private static var accent: Color { Color(nsColor: ThemeChrome.accentNSColor()) }

    /// Keeps the project names and the "Add Project…" text in one column.
    private static let leadingIconWidth: CGFloat = 18
    private static let rowPadding: CGFloat = 6

    private func projectRow(_ rowScope: Scope, title: String, subtitle: String) -> some View {
        let isSelected = scope == rowScope
        return HStack(spacing: 8) {
            removeButton(for: rowScope)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.rowPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Self.accent.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { scope = rowScope }
        .plumeID(
            AccessibilityID.settingsProjectRow,
            label: rowScope.root ?? "defaults",
            value: isSelected ? "selected" : nil,
            invoke: { scope = rowScope }
        )
    }

    /// Only a row with stored settings has anything to delete. A project
    /// found through a task keeps its row once its settings are gone.
    @ViewBuilder
    private func removeButton(for rowScope: Scope) -> some View {
        if let root = rowScope.root, configuration.repositories[root] != nil {
            let help = discoveredRoots.contains(root) ? "Clear this project's settings" : "Remove this project"
            Button {
                remove(root)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
                    .frame(width: Self.leadingIconWidth)
            }
            .buttonStyle(.borderless)
            .help(help)
            .plumeID(AccessibilityID.settingsProjectRemoveButton, label: root, invoke: { remove(root) })
        } else {
            Color.clear.frame(width: Self.leadingIconWidth, height: 1)
        }
    }

    private func remove(_ root: String) {
        settings.projectsConfiguration.repositories[root] = nil
        if !discoveredRoots.contains(root), scope == .project(root) { scope = .defaults }
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

        Picker(selection: nerdFont) {
            if isDefaults {
                Text(Self.name(NerdFontMode.automatic)).tag(NerdFontMode?.none)
            } else {
                Text("Default (\(Self.name(inherited.nerdFont ?? .automatic)))").tag(NerdFontMode?.none)
                Text(Self.name(NerdFontMode.automatic)).tag(NerdFontMode?.some(.automatic))
            }
            Text(Self.name(NerdFontMode.on)).tag(NerdFontMode?.some(.on))
            Text(Self.name(NerdFontMode.off)).tag(NerdFontMode?.some(.off))
        } label: {
            Text("Nerd Font icons")
            NerdFontPreview()
            Text("Automatic shows them in Plume's terminals unless your Ghostty config sets its own font-family.")
        }
        .plumeID(AccessibilityID.settingsProjectNerdFontPicker, value: settings.nerdFont?.rawValue ?? "default")

        NameListEditor(
            title: "Protected worktrees",
            caption: "Worktree folders that wt refuses to delete, rename or foreground.",
            prompt: "Name of worktree folder",
            display: NameListDisplay(own: settings.protectedWorktrees, inherited: inherited.protectedWorktrees ?? [], isDefaults: isDefaults),
            set: { names in update { $0.protectedWorktrees = names } }
        )
        NameListEditor(
            title: "Ignored pending checks",
            caption: "Checks whose pending state doesn't count, e.g. ones waiting for approval to run. A pass or fail still counts.",
            prompt: "Name of check",
            display: NameListDisplay(own: settings.ignoredPendingChecks, inherited: inherited.ignoredPendingChecks ?? [], isDefaults: isDefaults),
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

    /// The defaults row stores Automatic as nil, so it has one option for it.
    private var nerdFont: Binding<NerdFontMode?> {
        Binding(
            get: { isDefaults && settings.nerdFont == .automatic ? nil : settings.nerdFont },
            set: { value in update { $0.nerdFont = value } }
        )
    }

    private static func name(_ mode: NerdFontMode) -> String {
        switch mode {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }

    private static func name(_ kind: ForgeKind) -> String {
        switch kind {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .none: "None"
        }
    }
}

/// What a list setting shows. A project's nil list inherits the defaults
/// row's; once edited, its own list replaces the inherited one, even when
/// emptied, until "Use Default" clears it. The defaults row has nothing to
/// inherit, so it never offers "Use Default".
struct NameListDisplay: Equatable {
    let names: [String]
    let isInherited: Bool
    let offersUseDefault: Bool

    init(own: [String]?, inherited: [String], isDefaults: Bool) {
        if isDefaults {
            names = own ?? []
            isInherited = false
            offersUseDefault = false
        } else if let own {
            names = own
            isInherited = false
            offersUseDefault = true
        } else {
            names = inherited
            isInherited = true
            offersUseDefault = false
        }
    }

    /// The list after adding comma-separated `input`, skipping blanks and
    /// names already there. Edits start from whatever is shown, inherited
    /// or not.
    func adding(_ input: String) -> [String] {
        var updated = names
        for name in input.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if !updated.contains(name) { updated.append(name) }
        }
        return updated
    }

    func removing(_ name: String) -> [String] {
        names.filter { $0 != name }
    }
}

private struct NameListEditor: View {
    let title: String
    let caption: String
    let prompt: String
    let display: NameListDisplay
    let set: ([String]?) -> Void
    @State private var draft = ""

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(display.names, id: \.self) { name in
                    HStack {
                        Text(name)
                            .foregroundStyle(display.isInherited ? .secondary : .primary)
                        Button {
                            set(display.removing(name))
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(display.isInherited ? "Stop inheriting, and remove \(name) from this project" : "Remove \(name)")
                        .plumeID(AccessibilityID.settingsProjectListRemoveButton, label: "\(title): \(name)", invoke: {
                            set(display.removing(name))
                        })
                    }
                }
                if display.names.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                if display.isInherited {
                    Text("Inherited from Defaults")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if display.offersUseDefault {
                    Button("Use Default") { set(nil) }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                        .help("Inherit this list from Defaults")
                        .plumeID(AccessibilityID.settingsProjectListUseDefaultButton, label: title, invoke: { set(nil) })
                }
                HStack {
                    TextField(title, text: $draft, prompt: Text(prompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit(add)
                        .plumeID(AccessibilityID.settingsProjectField, label: title, value: draft, setValue: { draft = $0 })
                    Button("Add", action: add)
                        .plumeID(AccessibilityID.settingsProjectListAddButton, label: title, invoke: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } label: {
            Text(title)
            Text(caption)
        }
    }

    private func add() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let updated = display.adding(draft)
        draft = ""
        set(updated)
    }
}

/// The glyphs `wt` prints in each mode, in the bundled Nerd Font, so the
/// choice can be made by eye.
private struct NerdFontPreview: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            row("Nerd Font", TerminalUI(glyphSet: .nerd))
            row("Plain", TerminalUI(glyphSet: .plain))
        }
    }

    private func row(_ title: String, _ ui: TerminalUI) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 6) {
                ForEach(Array(Self.glyphs(ui).enumerated()), id: \.offset) { _, glyph in
                    Text(glyph.text).foregroundStyle(glyph.color)
                }
            }
            .font(Self.font)
        }
    }

    private static var font: Font {
        BundledFonts.isCodeAvailable ? .custom(BundledFonts.code, size: 13) : .system(size: 13, design: .monospaced)
    }

    /// The glyphs that differ between the sets, each in the color `wt`
    /// paints it. The plain set has no forge icon, so that one drops out.
    private static func glyphs(_ ui: TerminalUI) -> [(text: String, color: Color)] {
        [
            (ui.github, Color.secondary),
            (ui.gitlab, Color.secondary),
            (ui.checksPass, Color.green),
            (ui.checksFail, Color.red),
            (ui.checksPending, Color.yellow),
            (ui.merged, Color.purple),
            (ui.netOff, Color.red),
        ].filter { !$0.0.isEmpty }
    }
}
