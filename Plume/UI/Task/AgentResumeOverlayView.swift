import SwiftUI

/// Shown for an agent tab that has a prior session but no live process this
/// launch — e.g. right after relaunching Plume. Resuming or starting fresh
/// are both explicit choices; neither happens automatically.
struct AgentResumeOverlayView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Previous Conversation")
                .font(.headline)

            Text("This tab was running a Claude conversation before Plume closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !directoryExists {
                Label("The working directory no longer exists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button("Start Fresh", action: startFresh)
                Button("Resume", action: resume)
                    .buttonStyle(.borderedProminent)
                    .disabled(!directoryExists)
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var directoryExists: Bool {
        guard let path = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func resume() {
        AgentLauncher.launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }

    private func startFresh() {
        tab.agentSessionID = nil
    }
}
