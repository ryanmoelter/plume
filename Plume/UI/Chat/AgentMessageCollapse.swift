import SwiftUI

/// How much of another agent's message shows while it is collapsed.
///
/// A collapsed message keeps the same pieces it has expanded, just fewer of
/// them, so toggling it adds or removes rows below the ones already showing
/// rather than replacing them.
enum AgentMessageCollapse {
    /// Lines a collapsed message shows.
    static let lineLimit = 10
    /// A message that would hide fewer lines than this stays whole: the
    /// "Show more" row would take nearly the room it saves.
    static let minimumHiddenLines = 4
    /// The fewest lines a clipped last piece shows. A piece that would show
    /// fewer is dropped instead, and the piece before it takes the fade.
    static let minimumTailLines = 3

    /// Wrapped lines the markdown would take at `width`, from a rough average
    /// glyph width. It only decides where to cut, so being a line or two out
    /// costs nothing.
    static func estimatedLines(_ markdown: String, width: CGFloat) -> Int {
        let perLine = max(20, Int(width / 7))
        return markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
    }

    static func isCollapsible(lineCounts: [Int]) -> Bool {
        lineCounts.reduce(0, +) >= lineLimit + minimumHiddenLines
    }

    /// Where a collapsed message ends: how many of its pieces show, and the
    /// line count the last of them is clipped to, nil when it shows whole.
    static func cut(lineCounts: [Int]) -> (count: Int, tailLineLimit: Int?) {
        var used = 0
        for (index, lines) in lineCounts.enumerated() {
            let remaining = lineLimit - used
            if lines < remaining {
                used += lines
                continue
            }
            if lines == remaining { return (index + 1, nil) }
            if index > 0, remaining < minimumTailLines { return (index, nil) }
            return (index + 1, max(remaining, minimumTailLines))
        }
        return (lineCounts.count, nil)
    }
}

extension View {
    /// Fades out the last piece a collapsed agent message shows, clipped to
    /// its line limit where it has one.
    func collapsedTail(_ tail: ChatPiece.CollapsedTail?) -> some View {
        modifier(CollapsedTailFade(tail: tail))
    }
}

/// Applied to every piece, so a piece gaining or losing the fade changes
/// values rather than structure and keeps its state across the toggle.
private struct CollapsedTailFade: ViewModifier, ThemedView {
    @Environment(\.theme) var theme

    let tail: ChatPiece.CollapsedTail?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maxHeight, alignment: .top)
            .clipShape(TailClip(clips: maxHeight != nil))
            .mask {
                ZStack {
                    GeometryReader { proxy in
                        LinearGradient(stops: stops(height: proxy.size.height), startPoint: .top, endPoint: .bottom)
                    }
                    Color.black.opacity(tail == nil ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.2), value: tail == nil)
            }
    }

    private var maxHeight: CGFloat? {
        guard let limit = tail?.lineLimit else { return nil }
        let line = proseTypography.body
        return CGFloat(limit) * (line.lineHeight + line.lineSpacing)
    }

    /// Opaque down to the last two lines or so, then clear at the bottom
    /// edge. A piece shorter than that fades over most of its height.
    private func stops(height: CGFloat) -> [Gradient.Stop] {
        guard height > 0 else { return [.init(color: .black, location: 0)] }
        let fade = min(proseTypography.body.lineHeight * 2.5, height * 0.8)
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: 1 - fade / height),
            .init(color: .clear, location: 1)
        ]
    }
}

/// The view's bounds when clipping, otherwise those bounds grown far enough
/// that nothing is cut — a shape rather than a conditional `.clipped()`, so
/// toggling never restructures the chain.
private struct TailClip: Shape {
    let clips: Bool

    func path(in rect: CGRect) -> Path {
        Path(clips ? rect : rect.insetBy(dx: -100_000, dy: -100_000))
    }
}

/// The row closing a collapsible agent message: "Show more" while it is
/// collapsed, "Hide message" once it is open.
struct AgentMessageToggleRow: View, ThemedView {
    @Environment(\.theme) var theme

    let isExpanded: Bool
    /// The message's key, which tells one message's row from another's.
    let key: String
    let toggle: (() -> Void)?

    var body: some View {
        Button {
            toggle?()
        } label: {
            Label(isExpanded ? "Hide message" : "Show more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .font(typography.caption.font)
                .emphasis(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .plumeID(
            isExpanded ? AccessibilityID.agentMessageHide : AccessibilityID.agentMessageShowMore,
            label: key,
            invoke: toggle
        )
        .disabled(toggle == nil)
        .listItemPadding(vertical: false)
    }
}
