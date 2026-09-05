#if DEBUG
import AppKit
import os
import SwiftUI

/// Stands in for a hand on the trackpad, so the chat list can be scrolled
/// without UI scripting. Each run logs its progress so it is observable from
/// outside the app.
///
/// `PLUME_SCROLL_EXERCISE=<seconds>` jumps between messages spread across the
/// transcript on that interval. `PLUME_SCROLL_WHEEL=<points>` instead moves the
/// backing `NSScrollView` that many points per frame, reversing at either end,
/// which is the shape of a real trackpad scroll and what a lazy stack sees.
@MainActor
enum ScrollExercise {
    static let jumpInterval: Double? = ProcessInfo.processInfo.environment["PLUME_SCROLL_EXERCISE"]
        .flatMap(Double.init)
    static let wheelStep: Double? = ProcessInfo.processInfo.environment["PLUME_SCROLL_WHEEL"]
        .flatMap(Double.init)

    static func run(messages: [ChatMessage], proxy: ScrollViewProxy) async {
        guard messages.count >= 8 else { return }
        if let wheelStep, wheelStep > 0 {
            await wheel(step: wheelStep)
        } else if let jumpInterval, jumpInterval > 0 {
            await jump(messages: messages, proxy: proxy, interval: jumpInterval)
        }
    }

    private static func jump(messages: [ChatMessage], proxy: ScrollViewProxy, interval: Double) async {
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

    private static func wheel(step: Double) async {
        // The transcript renders a beat after the task starts, so the list
        // may not be tall enough to scroll yet.
        try? await Task.sleep(for: .seconds(2))
        guard let scrollView = tallestScrollView() else {
            Log.app.error("Scroll exercise found no scrollable chat list")
            return
        }
        let clip = scrollView.contentView
        var direction: CGFloat = -1
        var frames = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            var origin = clip.bounds.origin
            origin.y += direction * step
            if origin.y <= 0 { origin.y = 0; direction = 1 }
            if origin.y >= maxY { origin.y = maxY; direction = -1 }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            frames += 1
            if frames % 60 == 0 {
                Log.app.info("Scroll exercise wheel at y=\(Int(origin.y)) of \(Int(maxY))")
            }
        }
    }

    /// The chat list is the scroll view with the most content hidden beyond
    /// its viewport; the sidebar and code blocks are all shorter.
    private static func tallestScrollView() -> NSScrollView? {
        NSApp.windows
            .compactMap(\.contentView)
            .flatMap(scrollViews(in:))
            .max { overflow(of: $0) < overflow(of: $1) }
            .flatMap { overflow(of: $0) > 0 ? $0 : nil }
    }

    private static func overflow(of scrollView: NSScrollView) -> CGFloat {
        (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }
}
#endif
