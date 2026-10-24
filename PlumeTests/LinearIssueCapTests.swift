import Testing
@testable import Plume

struct LinearIssueCapTests {
    @Test func showsEverythingAtOrBelowTheLimit() {
        for total in [0, 1, 6] {
            let layout = LinearIssueCap.layout(total: total, isExpanded: false)
            #expect(layout.visibleCount == total)
            #expect(layout.toggleTitle == nil)
        }
    }

    @Test func noToggleWhenExpandedWithFewIssues() {
        #expect(LinearIssueCap.layout(total: 5, isExpanded: true).toggleTitle == nil)
    }

    @Test func collapsedShowsSixAndCountsTheHiddenOnes() {
        let layout = LinearIssueCap.layout(total: 10, isExpanded: false)
        #expect(layout.visibleCount == 6)
        #expect(layout.toggleTitle == "Show 4 more")
        #expect(layout.toggleSymbol == "chevron.down")
    }

    @Test func expandedShowsAllWithShowFewer() {
        let layout = LinearIssueCap.layout(total: 10, isExpanded: true)
        #expect(layout.visibleCount == 10)
        #expect(layout.toggleTitle == "Show fewer")
        #expect(layout.toggleSymbol == "chevron.up")
    }
}
