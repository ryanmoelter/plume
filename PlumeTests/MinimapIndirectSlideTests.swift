import CoreGraphics
import Foundation
import Testing
@testable import Plume

/// Only the hovered indirect row slides out, to where a prompt bar on its
/// row would end; the row it took over from slides home.
@MainActor
struct MinimapIndirectSlideTests {
    private func target(_ slide: MinimapIndirectSlide, _ id: String) -> CGFloat? {
        slide.rowIDs.firstIndex(of: id).map { slide.targets[$0] }
    }

    @Test func hoveringAnIndirectRowSlidesItOut() {
        var slide = MinimapIndirectSlide()
        slide.select("q1")
        #expect(target(slide, "q1") == 1)
        #expect(slide.targets.filter { $0 == 1 }.count == 1)
    }

    @Test func movingToAnotherIndirectRowSendsTheFirstHome() {
        var slide = MinimapIndirectSlide()
        slide.select("q1")
        slide.select("q2")
        #expect(target(slide, "q1") == 0)
        #expect(target(slide, "q2") == 1)
    }

    @Test func leavingSendsEveryRowHome() {
        var slide = MinimapIndirectSlide()
        slide.select("q1")
        slide.select(nil)
        #expect(slide.targets == [0, 0])
        #expect(slide.rowIDs.contains("q1"))
    }

    @Test func aRowHoveredAgainKeepsItsSlot() {
        var slide = MinimapIndirectSlide()
        slide.select("q1")
        let slot = slide.rowIDs.firstIndex(of: "q1")
        slide.select("q2")
        slide.select("q1")
        #expect(slide.rowIDs.firstIndex(of: "q1") == slot)
        #expect(target(slide, "q1") == 1)
        #expect(target(slide, "q2") == 0)
    }

    @Test func slidOutTheMarkEndsWhereAPromptBarWould() {
        let promptLength: CGFloat = 38.4
        for markLength: CGFloat in [3.5, 9.6] {
            let offset = MinimapIndirectSlide.offset(progress: 1, promptLength: promptLength, markLength: markLength)
            #expect(abs(offset + markLength - promptLength) < 0.0001)
        }
        #expect(MinimapIndirectSlide.offset(progress: 0, promptLength: promptLength, markLength: 3.5) == 0)
        #expect(MinimapIndirectSlide.offset(progress: 1, promptLength: 2, markLength: 3.5) == 0)
    }
}
