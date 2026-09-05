#if DEBUG
import os
import SwiftUI

/// Stands in for a hand on the trackpad, so the chat list can be scrolled
/// without UI scripting. `PLUME_SCROLL_EXERCISE=<seconds>` jumps between
/// messages spread across the transcript on that interval, and logs each jump
/// so the run is observable from outside the app.
@MainActor
enum ScrollExercise {
    static let interval: Double? = ProcessInfo.processInfo.environment["PLUME_SCROLL_EXERCISE"]
        .flatMap(Double.init)

    static func run(messages: [ChatMessage], proxy: ScrollViewProxy) async {
        guard let interval, interval > 0, messages.count >= 8 else { return }
        let step = max(1, messages.count / 12)
        var targets = stride(from: 0, to: messages.count, by: step).map { messages[$0].id }
        targets += targets.reversed()
        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            let target = targets[index % targets.count]
            withAnimation(.easeInOut(duration: interval * 0.8)) {
                proxy.scrollTo(target, anchor: .top)
            }
            Log.app.info("Scroll exercise jumped to target \(index % targets.count) of \(targets.count)")
            index += 1
        }
    }
}
#endif
