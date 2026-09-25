import SwiftUI

/// The ignored pending checks set in git config, read-only here because
/// `wt` and `stack` own them.
struct GitConfigIgnoredChecksSection: View {
    @State private var names: [String]?

    var body: some View {
        Section {
            if let names {
                if names.isEmpty {
                    Text("None found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                    }
                }
            } else {
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("From git config")
        } footer: {
            Text("Found in your global git config, and shared with wt and stack. A repository's own git config can add more.")
                .foregroundStyle(.secondary)
        }
        .task {
            let found = await Task.detached { IgnoredChecksResolver.globalGitConfigNames() }.value
            var seen = Set<String>()
            names = found.filter { seen.insert($0).inserted }
        }
    }
}
