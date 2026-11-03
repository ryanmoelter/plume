import SwiftUI

/// Settings ▸ Agents' list of the skills Plume bundles for Claude Code, with
/// what is installed under each name.
struct BundledSkillsSection: View {
    @State private var status = BundledSkillsStatus.shared
    @State private var pendingReplace: BundledSkill?

    var body: some View {
        Section {
            ForEach(status.entries) { entry in
                row(entry)
            }
            if let error = status.error(for: .settings) {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Plume skills")
                Spacer()
                if status.entries.contains(where: { $0.state == .notInstalled }) {
                    Button("Install All", action: installAll)
                        .plumeID(AccessibilityID.settingsSkillsInstallAllButton, invoke: installAll)
                        .disabled(status.isChanging)
                }
            }
        } footer: {
            Text("Plume copies these into `~/.claude/skills`, where they teach Claude Code the `plume` command.")
                .foregroundStyle(.secondary)
        }
        .onAppear { status.refresh() }
        .confirmationDialog(
            "Replace \(pendingReplace?.name ?? "")?",
            isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }),
            presenting: pendingReplace
        ) { skill in
            Button("Move to Trash and Replace", role: .destructive) {
                status.install(skill, replacing: true)
            }
            .disabled(status.isChanging)
        } message: { skill in
            if BundledSkills.isSymlink(BundledSkills.skillsDirectory.appending(path: skill.name)) {
                Text("Plume removes the link ~/.claude/skills/\(skill.name), leaves the folder it points to alone, then installs its own.")
            } else {
                Text("Plume moves ~/.claude/skills/\(skill.name) to the Trash, then installs its own.")
            }
        }
    }

    private func installAll() {
        status.installMissing(on: .settings)
    }

    private func row(_ entry: BundledSkillsStatus.Entry) -> some View {
        let skill = entry.skill
        return LabeledContent {
            HStack {
                Text(Self.label(for: entry.state))
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.settingsSkillState, label: skill.name, value: Self.label(for: entry.state))
                switch entry.state {
                case .notInstalled:
                    button("Install", id: AccessibilityID.settingsSkillInstallButton, skill) { status.install(skill) }
                case .installed:
                    button("Remove", id: AccessibilityID.settingsSkillRemoveButton, skill) { status.uninstall(skill) }
                case .outdated:
                    button("Update", id: AccessibilityID.settingsSkillUpdateButton, skill) { status.install(skill) }
                    button("Remove", id: AccessibilityID.settingsSkillRemoveButton, skill) { status.uninstall(skill) }
                case .ownedByOther, .modified:
                    button("Replace…", id: AccessibilityID.settingsSkillReplaceButton, skill) { pendingReplace = skill }
                }
            }
        } label: {
            Text(skill.name)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func button(
        _ title: String,
        id: String,
        _ skill: BundledSkill,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .plumeID(id, label: skill.name, invoke: action)
            .disabled(status.isChanging)
    }

    private static func label(for state: BundledSkills.State) -> String {
        switch state {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .outdated: "Out of date"
        case .ownedByOther: "Another skill has this name"
        case .modified: "Edited since Plume installed it"
        }
    }
}
