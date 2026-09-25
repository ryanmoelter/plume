import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text(AppIdentity.displayName)
                        .font(.title2)
                    Text("Version \(shortVersion) (\(buildVersion))")
                        .foregroundStyle(.secondary)
                    Text("Made by Ryan Moelter")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Link(destination: URL(string: "https://heypenny.money")!) {
                    HStack(spacing: 10) {
                        Image("HeypennyIcon")
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Heypenny")
                                .foregroundStyle(.primary)
                            Text("heypenny.money")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .plumeID(AccessibilityID.settingsAboutHeypennyLink)
            } header: {
                Text("More from Ryan")
            }

            Section {
                Link("Ghostty", destination: URL(string: "https://ghostty.org")!)
                Link("libghostty-spm", destination: URL(string: "https://github.com/Lakr233/libghostty-spm")!)
                Link("Sparkle", destination: URL(string: "https://sparkle-project.org")!)
            } header: {
                Text("Credits")
            } footer: {
                Text("Terminals run on Ghostty, through libghostty-spm. Updates use Sparkle.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
