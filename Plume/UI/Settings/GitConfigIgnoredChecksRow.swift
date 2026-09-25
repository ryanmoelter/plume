import SwiftUI

/// The ignored pending checks set in git config, read-only here because
/// `wt` and `stack` own them.
struct GitConfigIgnoredChecksRow: View {
    @State private var names: [String]?

    var body: some View {
        LabeledContent {
            content
        } label: {
            Text("From global git config")
            Text("Shared with `wt` and `stack`, if installed")
                .foregroundStyle(.secondary)
        }
        .task {
            let found = await Task.detached { IgnoredChecksResolver.globalGitConfigNames() }.value
            var seen = Set<String>()
            names = found.filter { seen.insert($0).inserted }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let names {
            if names.isEmpty {
                Text("None found")
                    .foregroundStyle(.secondary)
            } else {
                Text(names.joined(separator: ", "))
            }
        } else {
            Text("Checking…")
                .foregroundStyle(.secondary)
        }
    }
}
