#if DEBUG
import SwiftUI

/// Debug-only Settings section for exercising both update paths — the
/// installer swap and the scheduled background check — without reinstalling
/// or waiting on Sparkle's own schedule. `#if DEBUG` end to end; compiles to
/// nothing in Release. `scripts/debug/serve-test-appcast.sh` builds the test
/// feed this section points at.
struct UpdatesDebugSection: View {
    @State private var settings = AppSettings.shared
    @State private var updates = UpdateController.shared
    @State private var feedURLText = UpdateController.shared.debugFeedURLOverride

    var body: some View {
        Section {
            Picker("Install source", selection: installSourceOverrideBinding) {
                Text("Auto (detected: \(updates.isHomebrewInstall ? "Homebrew" : "Plume"))")
                    .tag(UpdateInstallSource?.none)
                Text("Plume").tag(UpdateInstallSource?.some(.plume))
                Text("Homebrew").tag(UpdateInstallSource?.some(.homebrew))
            }
            .plumeID(
                AccessibilityID.debugUpdatesInstallSourcePicker,
                value: settings.updateInstallSourceOverride?.rawValue ?? "auto"
            )

            HStack {
                TextField("Feed URL override", text: $feedURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { updates.debugApplyFeedURLOverride(feedURLText) }
                    .plumeID(AccessibilityID.debugUpdatesFeedURLField, value: feedURLText)
                Text(updates.isRunning ? "Running" : "Not running")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Check in background now") { updates.debugCheckForUpdatesInBackground() }
                    .plumeID(AccessibilityID.debugUpdatesCheckBackgroundButton)
                    .disabled(!updates.isRunning || !updates.canCheckForUpdates)
                Spacer()
            }

            Button("Reset update state") { updates.debugResetUpdateState() }
                .plumeID(AccessibilityID.debugUpdatesResetStateButton)
        } header: {
            Text("Updates (Debug)")
        } footer: {
            Text(footerText)
                .foregroundStyle(.secondary)
        }
    }

    private var installSourceOverrideBinding: Binding<UpdateInstallSource?> {
        Binding(
            get: { settings.updateInstallSourceOverride },
            set: { settings.updateInstallSourceOverride = $0 }
        )
    }

    private var footerText: String {
        var notes = [
            "Check in background now exercises the gentle scheduled path — a sidebar row only, never a window. " +
                "Reset clears Sparkle's skipped-version and last-check state; an open gentle-reminder session " +
                "can't be closed this way and needs a relaunch to fully reset.",
        ]
        if feedURLText.isEmpty, updates.isRunning {
            notes.append("Clearing the feed while the updater is running only takes effect on relaunch — Sparkle can't be stopped.")
        }
        return notes.joined(separator: " ")
    }
}
#endif
