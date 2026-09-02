import SwiftUI

/// Shown for an agent tab with a stored session whose working directory no
/// longer exists, so auto-resume is withheld until the user resolves it.
struct AgentMissingDirectoryView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "questionmark.folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Previous Conversation")
                .font(.headline)

            Label("The working directory no longer exists.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
    }
}
