import SwiftUI

/// The mark on every control that opens a link outside Plume, so each one
/// reads as the same action.
struct LinkOpenIcon: View, ThemedView {
    @Environment(\.theme) var theme

    var body: some View {
        Image(systemName: "arrow.up.forward.square")
            .foregroundStyle(colors.selection)
    }
}
