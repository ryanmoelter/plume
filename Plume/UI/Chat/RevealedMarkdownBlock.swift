import SwiftUI

/// One markdown block the stream wrote, typed out as it arrives.
///
/// The piece keeps this view alive across the moment its block completes —
/// same id, same content case — so the reveal carries on from where it had
/// got to instead of the block snapping to full. That handoff is the whole
/// reason the arriving block is an ordinary `.markdown` piece rather than a
/// kind of its own.
struct RevealedMarkdownBlock: View {
    let source: String
    /// Whether the stream is still writing this block.
    let isArriving: Bool
    let isAgentVoice: Bool

    @Environment(\.revealClock) private var clock
    @State private var settings = AppSettings.shared
    @State private var progress = RevealProgress()
    @State private var revealedCount: Double = 0

    var body: some View {
        Group {
            if settings.animateCharacterReveal {
                CharacterReveal(revealedCount: revealedCount, text: source) { revealed in
                    MarkdownView(revealed, isAgentVoice: isAgentVoice)
                }
            } else {
                MarkdownView(source, isAgentVoice: isAgentVoice)
            }
        }
        .onChange(of: source, initial: true) { _, text in reveal(text) }
        // The block has stopped growing: type out whatever it still owes
        // rather than letting completion cut the reveal short.
        .onChange(of: isArriving) { _, arriving in
            guard !arriving else { return }
            run(progress.finish(source))
        }
    }

    /// A block first seen while the stream is writing it types from nothing.
    /// One first seen already settled — a tab switched to mid-turn, or a row
    /// the lazy stack has realized again — shows what has already arrived.
    private func reveal(_ text: String) {
        let isFirstSight = progress.revealedCount == nil
        if isFirstSight {
            guard isArriving else {
                run(progress.advance(to: text))
                return
            }
            progress.start()
        }
        // Only a block opening waits its turn. A reveal already under way
        // has the clock's slot, and delaying it again would compound.
        run(progress.advance(to: text), waits: isFirstSight)
    }

    private func run(_ animation: Animation?, waits: Bool = false) {
        guard let animation else {
            revealedCount = Double(source.count)
            return
        }
        let delay = waits ? (clock?.wait() ?? 0) : 0
        clock?.hold(for: delay + max(0, progress.deadline.timeIntervalSinceNow))
        withAnimation(delay > 0 ? animation.delay(delay) : animation) {
            revealedCount = Double(source.count)
        }
    }
}
