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
                appLink(
                    "Notability",
                    tagline: "Notes that help you think (my day job)",
                    icon: "NotabilityIcon",
                    destination: URL(string: "https://notability.com")!
                )
                .plumeID(AccessibilityID.settingsAboutNotabilityLink)
                appLink(
                    "Heypenny",
                    tagline: "Split bills fairly (my side project)",
                    icon: "HeypennyIcon",
                    destination: URL(string: "https://heypenny.money")!
                )
                .plumeID(AccessibilityID.settingsAboutHeypennyLink)
            } header: {
                Text("More from Ryan")
            }

            Section {
                creditLink("Ghostty", destination: URL(string: "https://ghostty.org")!)
                creditLink("libghostty-spm", destination: URL(string: "https://github.com/Lakr233/libghostty-spm")!)
                creditLink("Sparkle", destination: URL(string: "https://sparkle-project.org")!)
            } header: {
                Text("Credits")
            }
        }
        .formStyle(.grouped)
    }

    private func appLink(_ name: String, tagline: String, icon: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 10) {
                Image(icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .foregroundStyle(.primary)
                    Text(tagline)
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
    }

    private func creditLink(_ title: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right.square")
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.tint)
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
