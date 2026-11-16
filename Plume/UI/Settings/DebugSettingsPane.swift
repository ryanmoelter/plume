#if DEBUG
import SwiftData
import SwiftUI

struct DebugSettingsPane: View {
    @Environment(\.modelContext) private var context
    @Query private var groups: [TaskGroup]

    var body: some View {
        Form {
            Section {
                Button("Seed fixtures") {
                    let existingGroups = (try? context.fetch(FetchDescriptor<TaskGroup>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
                    SidebarFixtures.seed(in: context, existingGroups: existingGroups)
                }
                .plumeID(AccessibilityID.settingsSeedFixturesButton)
                .help("Seed a \"\(SidebarFixtures.groupName)\" group covering every sidebar state")
                Button("Remove fixtures") {
                    SidebarFixtures.remove(in: context, existingGroups: groups)
                }
                .plumeID(AccessibilityID.settingsRemoveFixturesButton)
                .disabled(!SidebarFixtures.hasFixtures(in: groups))
                .help("Delete the \"\(SidebarFixtures.groupName)\" group and every task in it")
            } header: {
                Text("Fixtures")
            }

            AgentInstallationDebugSection()
            RevealTuningDebugSection()
            UpdatesDebugSection()
            ThemeDebugSection()
            GreetingDebugSection()
        }
        .formStyle(.grouped)
    }
}
#endif
