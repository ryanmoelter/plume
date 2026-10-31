import SwiftUI

/// Variant B: one chip naming the whole destination, which opens a popover
/// listing the three choices side by side.
struct HomeDestinationChip: View, ThemedView {
    let model: HomeComposerModel
    let placement: HomeComposerPlacement
    @Environment(\.theme) var theme
    @State private var isPresented = false

    private var summary: String {
        [model.groupTitle, model.projectTitle, model.workspaceTitle.lowercased()].joined(separator: " › ")
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            ComposerSegmentLabel(
                systemImage: "mappin.and.ellipse",
                text: summary,
                indicator: .menu,
                foreground: colors.foreground.opacity(colors.emphasis[.secondary]),
                height: dimensions.composerControlHeight
            )
        }
        .buttonStyle(.plain)
        .font(typography.caption.font)
        .help("Where the new task goes")
        .plumeID(AccessibilityID.homeComposerDestinationChip, value: summary) { isPresented.toggle() }
        .popover(isPresented: $isPresented, arrowEdge: placement == .top ? .bottom : .top) {
            HomeDestinationPopover(model: model)
        }
    }
}

private struct HomeDestinationPopover: View {
    let model: HomeComposerModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            section("Group") {
                option(HomeDestinationCatalog.noGroupTitle, isSelected: model.destination.groupID == nil, id: AccessibilityID.homeComposerGroupOption) {
                    model.chooseGroup(nil)
                }
                ForEach(model.catalog.groups) { group in
                    option(group.name, isSelected: model.destination.groupID == group.id, id: AccessibilityID.homeComposerGroupOption) {
                        model.chooseGroup(group.id)
                    }
                }
            }
            section("Project") {
                ForEach(model.catalog.projects) { project in
                    option(project.name, isSelected: model.destination.projectPath == project.path, id: AccessibilityID.homeComposerProjectOption) {
                        model.chooseProject(project.path)
                    }
                }
                Button("Choose Folder…", action: HomeDestinationMenus(model: model).chooseFolder)
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
            section("Workspace") {
                ForEach(model.workspaceChoices, id: \.self) { choice in
                    option(choice.title, isSelected: model.destination.workspace == choice, id: AccessibilityID.homeComposerWorkspaceOption) {
                        model.chooseWorkspace(choice)
                    }
                }
            }
        }
        .padding(14)
        .fixedSize()
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            rows()
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    private func option(_ title: String, isSelected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .plumeID(id, label: title, value: isSelected ? "selected" : nil, invoke: action)
    }
}
