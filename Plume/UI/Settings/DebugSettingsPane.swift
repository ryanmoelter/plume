#if DEBUG
import SwiftData
import SwiftUI

struct DebugSettingsPane: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                Button("Seed fixtures") {
                    let existingGroups = (try? context.fetch(FetchDescriptor<TaskGroup>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
                    SidebarFixtures.seed(in: context, existingGroups: existingGroups)
                }
                .plumeID(AccessibilityID.settingsSeedFixturesButton)
                .help("Seed a \"\(SidebarFixtures.groupName)\" group covering every sidebar state")
            } header: {
                Text("Fixtures")
            }

            AgentInstallationDebugSection()
            RevealTuningDebugSection()
            UpdatesDebugSection()
        }
        .formStyle(.grouped)
    }
}
#endif
