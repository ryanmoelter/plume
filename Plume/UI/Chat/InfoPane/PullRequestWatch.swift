import SwiftUI

extension View {
    /// Holds a `PullRequestStore` watch on `directory` for as long as the view
    /// is mounted, feeding it the branch `GitStateStore` already publishes.
    /// The caller must hold the git watch itself.
    func pullRequestWatch(directory: String?, isEnabled: Bool) -> some View {
        modifier(PullRequestWatch(wanted: isEnabled ? directory : nil))
    }
}

/// Balances the store's refcount: every directory it watched is released
/// when the directory changes, the setting turns off, or the view goes away.
private struct PullRequestWatch: ViewModifier {
    let wanted: String?

    @State private var watched: String?

    private struct Key: Equatable {
        let directory: String?
        let gitState: GitState?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Key(directory: wanted, gitState: GitStateStore.shared.state(for: wanted)), initial: true) { _, key in
                if key.directory != watched {
                    if let watched { PullRequestStore.shared.release(watched) }
                    if let directory = key.directory { PullRequestStore.shared.watch(directory) }
                    watched = key.directory
                }
                if let directory = key.directory {
                    PullRequestStore.shared.apply(gitState: key.gitState, for: directory)
                }
            }
            .onDisappear {
                if let watched { PullRequestStore.shared.release(watched) }
                watched = nil
            }
    }
}
