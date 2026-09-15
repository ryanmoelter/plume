import SwiftUI

/// An ellipsis whose dots light one after another, the way a chat app shows
/// someone typing. Shared by the sidebar badge and the chat caption, and
/// stepped off one fixed reference date so every instance stays in step.
///
/// Two layers of the same SF Symbol: a dimmed ellipsis underneath, and on top
/// a full-colour copy per dot, each masked to its third of the glyph and
/// faded in for its turn. That is what `.symbolEffect(.variableColor…)` drew,
/// but a symbol effect is not the render-server animation it looks like:
/// RenderBox re-rasterizes the glyph in-process on every frame and then blocks
/// the main thread on the render server's commit, which cost about a tenth of
/// a core per instance and starved wheel-event handling while any agent was
/// working. A stepped opacity fade only animates for a fraction of each step.
struct WorkingEllipsis: View {
    var color: Color

    static let step: TimeInterval = 0.5
    static let dotCount = 3
    /// Three lit dots, then a frame with none lit.
    static let phaseCount = dotCount + 1
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.epoch, by: Self.step)) { context in
            let lit = Self.litDot(at: context.date)
            Image(systemName: "ellipsis")
                .foregroundStyle(color.opacity(0.3))
                .overlay {
                    ForEach(0..<Self.dotCount, id: \.self) { index in
                        Image(systemName: "ellipsis")
                            .foregroundStyle(color)
                            .mask { DotMask(index: index) }
                            .opacity(index == lit ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: lit)
        }
        .accessibilityLabel("Working")
    }

    /// Which dot is lit at `date`, cycling from the shared epoch. `dotCount`
    /// means none.
    static func litDot(at date: Date) -> Int {
        let steps = (date.timeIntervalSince(epoch) / step).rounded(.down)
        return Int(steps.truncatingRemainder(dividingBy: Double(phaseCount)))
    }
}

/// One third of the glyph, since the ellipsis places its dots evenly.
private struct DotMask: View {
    let index: Int

    var body: some View {
        GeometryReader { proxy in
            let third = proxy.size.width / CGFloat(WorkingEllipsis.dotCount)
            Rectangle()
                .frame(width: third)
                .offset(x: third * CGFloat(index))
        }
    }
}

#Preview {
    WorkingEllipsis(color: .accentColor)
        .padding()
}
