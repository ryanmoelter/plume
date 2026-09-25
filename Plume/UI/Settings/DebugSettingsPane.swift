#if DEBUG
import SwiftData
import SwiftUI

struct DebugSettingsPane: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsThemeModifier.key) private var themesSettingsWindow = false

    var body: some View {
        Form {
            Section {
                Toggle("Tint with the terminal theme", isOn: $themesSettingsWindow)
                    .plumeID(
                        AccessibilityID.settingsThemeToggle,
                        value: String(themesSettingsWindow),
                        setValue: { themesSettingsWindow = ($0 == "true" || $0 == "1") }
                    )
            } header: {
                Text("Settings Window")
            }


            Section {
                Button("Seed Fixtures") {
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
