import SwiftUI

extension View {
    /// Asks `LinearStore` to keep `identifiers` fetched for as long as the
    /// view is mounted. An empty set wants nothing.
    func linearIssueWatch(_ identifiers: Set<String>) -> some View {
        modifier(LinearIssueWatch(identifiers: identifiers))
    }
}

private struct LinearIssueWatch: ViewModifier {
    let identifiers: Set<String>

    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: identifiers, initial: true) { _, wanted in
                LinearStore.shared.setWanted(wanted, owner: owner)
            }
            // A recycled row reappears without its `onChange` firing again.
            .onAppear {
                LinearStore.shared.setWanted(identifiers, owner: owner)
            }
            .onDisappear {
                LinearStore.shared.setWanted([], owner: owner)
            }
    }
}
