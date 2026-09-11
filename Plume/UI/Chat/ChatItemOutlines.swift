#if DEBUG
import SwiftUI

/// Draws a box around every lazy item in the chat list, so the piece
/// boundaries the hang depends on can be seen rather than inferred.
///
/// `LazyVStack` never settles when the items it has realized differ in height
/// by a large factor, so reading `docs/chat-list-hang.md` means knowing where
/// one item ends and the next begins — which is invisible by design, because
/// several pieces of one message are drawn to read as a single bubble. DEBUG
/// only, and off until asked for.
@MainActor
@Observable
final class ChatItemOutlines {
    static let shared = ChatItemOutlines()

    var isEnabled = false

    private init() {}

    /// A stable colour per item, so a piece keeps its box across a rebuild
    /// and neighbouring boxes stay told apart.
    static func color(for id: String) -> Color {
        let hue = Double(abs(id.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.9, brightness: 0.95)
    }
}

extension View {
    /// Outlines this item and labels it with its piece kind and height.
    func chatItemOutline(id: String, kind: @autoclosure () -> String) -> some View {
        modifier(ChatItemOutline(id: id, kind: kind()))
    }
}

private struct ChatItemOutline: ViewModifier {
    let id: String
    let kind: String

    @State private var outlines = ChatItemOutlines.shared
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        if outlines.isEnabled {
            content
                .overlay {
                    Rectangle()
                        .strokeBorder(ChatItemOutlines.color(for: id), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    Text("\(kind) \(Int(height))")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .background(ChatItemOutlines.color(for: id))
                        .allowsHitTesting(false)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    height = newHeight
                }
        } else {
            content
        }
    }
}
#endif
