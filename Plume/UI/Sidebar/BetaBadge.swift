import SwiftUI

/// Marks an unproven feature — one built but never driven end to end.
///
/// Worktree create/delete moved onto `GitService` and have not been
/// exercised since. This flags that in the UI rather than blocking on
/// verification. Give the tooltip wording that names what specifically is
/// unverified at that call site, not this generic explanation.
struct BetaBadge: View, ThemedView {
    @Environment(\.theme) var theme

    var body: some View {
        Text("Beta")
            .font(typography.caption.semibold)
            .foregroundStyle(colors.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(colors.warning.opacity(colors.emphasis[.subtle])))
    }
}

extension BetaBadge {
    /// A plain-text stand-in for menu items and alert buttons, which render
    /// as native AppKit items and cannot host a custom view.
    static func menuTitle(_ title: String) -> String {
        "\(title) (Beta)"
    }
}

#Preview {
    HStack {
        Text("New Worktree").font(.headline)
        BetaBadge()
    }
    .padding()
}
