import SwiftUI

/// The mark on every control that opens a link outside Plume, so each one
/// reads as the same action.
struct LinkOpenIcon: View, ThemedView {
    @Environment(\.theme) var theme

    var isFilled = false

    var body: some View {
        Image(systemName: isFilled ? "arrow.up.forward.square.fill" : "arrow.up.forward.square")
            .foregroundStyle(colors.selection)
    }
}
