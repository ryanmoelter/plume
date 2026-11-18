import AppKit
import Testing
@testable import Plume

/// `scrollChat`'s driver, ticked by hand: a handover from the display link to
/// the timer measures no interval across the silence, a list that leaves its
/// window ends the run with an error, and a `by` run stops after scrolling its
/// distance even when the offset shifts under it.
@MainActor
struct ScrollChatDriverTests {
    private static let frame = 1.0 / 120

    @Test func aClockHandoverMeasuresNoIntervalAcrossTheSilence() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        var result: Result<ScrollHitchReport, Error>?
        let driver = ScrollChatDriver(
            controller: controller, destination: .bottom, clockChoice: .auto,
            params: ScrollChatParams(to: "bottom", speed: 1, maxSeconds: 1.5)
        ) { result = $0 }
        driver.start()
        let t0 = CACurrentMediaTime()
        driver.tick(at: t0, period: Self.frame)
        driver.tick(at: t0 + Self.frame, period: Self.frame)
        driver.watchdogFired(at: driver.watchdogDue)

        var now = t0 + 1
        while result == nil {
            driver.tick(at: now, period: Self.frame)
            now += Self.frame
        }

        let report = try #require(try result?.get())
        let longest = try #require(report.intervalMs?.max)
        #expect(longest < Self.frame * 1000 + 1)
    }

    @Test func aListThatLeavesItsWindowEndsTheRun() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        var result: Result<ScrollHitchReport, Error>?
        let driver = ScrollChatDriver(
            controller: controller, destination: .bottom, clockChoice: .timer,
            params: ScrollChatParams(to: "bottom")
        ) { result = $0 }
        driver.start()
        let t0 = CACurrentMediaTime()
        driver.tick(at: t0, period: Self.frame)
        window.contentView = nil
        driver.tick(at: t0 + Self.frame, period: Self.frame)

        let finished = try #require(result)
        #expect(throws: ControlError.self) { try finished.get() }
        #expect(!ScrollHitchProbe.isActive)
    }

    @Test func aByRunScrollsItsDistanceWhenTheOffsetShifts() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        var result: Result<ScrollHitchReport, Error>?
        let driver = ScrollChatDriver(
            controller: controller, destination: .by(300), clockChoice: .timer,
            params: ScrollChatParams(by: 300, speed: 4000, settle: 0)
        ) { result = $0 }
        driver.start()
        var now = CACurrentMediaTime()
        driver.tick(at: now, period: Self.frame)
        now += Self.frame
        driver.tick(at: now, period: Self.frame)
        // What the list does to keep the reader's place when a row above grows.
        readerScroll(controller, to: controller.scrollView.contentView.bounds.origin.y + 10)
        while result == nil {
            now += Self.frame
            driver.tick(at: now, period: Self.frame)
        }

        let report = try #require(try result?.get())
        #expect(abs(report.distance - 300) < 0.5)
        #expect(abs(report.endOffset - report.startOffset - 310) < 1)
    }

    /// Scrolled to the top, with far more rows than fit.
    private func makeList() -> (ChatListController, NSWindow) {
        let controller = ChatListController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        let pieces = (0..<200).map { index in
            ChatPiece(
                id: "m/\(index)", messageID: "m", role: .assistant,
                content: .markdown(.paragraph("Paragraph \(index) of a reply long enough to scroll."), index: index),
                wash: .none
            )
        }
        controller.update(ChatListInputs(pieces: pieces))
        layOut(controller)
        readerScroll(controller, to: 0)
        layOut(controller)
        controller.finishAnimations()
        layOut(controller)
        return (controller, window)
    }

    private func close(_ controller: ChatListController, _ window: NSWindow) {
        controller.tearDown()
        window.close()
    }

    private func readerScroll(_ controller: ChatListController, to y: CGFloat) {
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        controller.scrollView.reflectScrolledClipView(clip)
    }

    /// An offscreen window runs no layout of its own.
    private func layOut(_ controller: ChatListController) {
        for _ in 0..<2 {
            controller.documentView.needsLayout = true
            controller.documentView.layoutSubtreeIfNeeded()
        }
    }
}
