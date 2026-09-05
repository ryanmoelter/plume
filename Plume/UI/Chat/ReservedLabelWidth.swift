import SwiftUI

/// A button whose title changes between a fixed set of labels without the
/// control resizing under the pointer.
///
/// The widest label is laid out but never drawn, and the visible title is
/// overlaid on it — so the width comes from measuring the real labels in the
/// font actually in effect, rather than from a guessed constant.
struct ReservedWidthButton: View {
    let title: String
    let labels: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(labels, id: \.self) { label in
                    Text(label).hidden()
                }
                Text(title)
            }
        }
    }
}
