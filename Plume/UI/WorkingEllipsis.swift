import SwiftUI

/// An ellipsis whose dots light one after another, the way a chat app shows
/// someone typing. Shared by the sidebar badge and the chat caption, and
/// stepped off one fixed reference date so every instance stays in step.
///
/// Drawn as three text glyphs stepped by a `TimelineView`, not as an SF
/// Symbol with `.symbolEffect(.variableColor…)`. A symbol effect looks like a
/// render-server animation but is not one: RenderBox re-rasterizes the glyph
/// in-process on every frame and then blocks the main thread on the render
/// server's commit, which cost the app about a tenth of a core per instance
/// and starved wheel-event handling while any agent was working.
struct WorkingEllipsis: View {
    var color: Color

    static let step: TimeInterval = 0.35
    static let dotCount = 3
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.epoch, by: Self.step)) { context in
            let lit = Self.litDot(at: context.date)
            (0..<Self.dotCount).reduce(Text("")) { text, index in
                text + Text("•").foregroundStyle(color.opacity(index == lit ? 1 : 0.3))
            }
        }
        .accessibilityLabel("Working")
    }

    /// Which dot is lit at `date`, cycling from the shared epoch.
    static func litDot(at date: Date) -> Int {
        let steps = (date.timeIntervalSince(epoch) / step).rounded(.down)
        return Int(steps.truncatingRemainder(dividingBy: Double(dotCount)))
    }
}

#Preview {
    WorkingEllipsis(color: .accentColor)
        .padding()
}
