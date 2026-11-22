import Foundation
import SwiftData
import Testing
@testable import Plume

/// A task row with child sessions: every agent takes a header, with children
/// nested under their parent's. A sole top-level agent keeps its lines under
/// its own header; several hoist what they share. A child shows only the lines
/// that differ from its parent's, and every header after the fourth folds
/// behind a toggle.
@MainActor
struct TaskRowChildLinesTests {
    private let open = PullRequestFetchState.pullRequest(PullRequest(number: 42, state: .open, isDraft: false))

    private func agent(
        _ title: String,
        _ directory: String?,
        branch: String? = nil,
        pullRequest: PullRequestFetchState? = nil,
        depth: Int = 0,
        id: UUID = UUID()
    ) -> TaskRowDetails.AgentGroup {
        TaskRowDetails.AgentGroup(
            header: TaskRowDetails.AgentHeader(tabID: id, title: title, status: .awaitingReply, depth: depth),
            workspace: TaskRowDetails.DirectoryGroup(directory: directory, branch: branch, pullRequest: pullRequest)
        )
    }

    private func headers(_ lines: [TaskRowDetails.Line]) -> [String] {
        lines.compactMap { if case .agentHeader(let header) = $0 { header.title } else { nil } }
    }

    /// Every header's parent label, top-level headers included as nil.
    private func parentLabels(_ lines: [TaskRowDetails.Line]) -> [String?] {
        lines.compactMap { line -> String?? in
            if case .agentHeader(let header) = line { .some(header.parentLabel) } else { .none }
        }
    }

    @Test func aSoleTopLevelAgentKeepsItsLinesUnderItsOwnHeader() {
        let parentHeader = TaskRowDetails.AgentHeader(tabID: UUID(), title: "Parent", status: .awaitingReply)
        var childHeader = TaskRowDetails.AgentHeader(tabID: UUID(), title: "Child", status: .awaitingReply, depth: 1)
        let workspace = TaskRowDetails.DirectoryGroup(directory: "/Users/me/Plume", branch: "main", pullRequest: open)
        let lines = TaskRowDetails.lines(
            agents: [
                TaskRowDetails.AgentGroup(header: parentHeader, workspace: workspace),
                TaskRowDetails.AgentGroup(header: childHeader, workspace: workspace),
            ],
            taskLines: [.linearOverflow(1)]
        )
        childHeader.parentLabel = "Parent"
        #expect(lines == [
            .linearOverflow(1),
            .agentHeader(parentHeader),
            .project("Plume"),
            .branch("main"),
            .pullRequest(directory: "/Users/me/Plume", state: open),
            .agentHeader(childHeader),
        ])
        #expect(TaskRowDetails.agentGroupNesting(lines) == [[], [1], [1], [1], [1], [1, 5]])
    }

    @Test func aChildShowsOnlyTheLinesThatDifferFromItsParents() {
        let lines = TaskRowDetails.lines(agents: [
            agent("Parent", "/Users/me/Plume", branch: "main"),
            agent("Child", "/Users/me/Plume-fix", branch: "fix", depth: 1),
        ])
        #expect(Array(lines.suffix(3)) == [lines[3], .project("Plume-fix"), .branch("fix")])
    }

    @Test func aChildInAnotherCheckoutKeepsAMatchingBranch() {
        let child = TaskRowDetails.lines(
            of: TaskRowDetails.DirectoryGroup(directory: "/a/Plume", branch: "main"),
            differingFrom: TaskRowDetails.DirectoryGroup(directory: "/b/Plume", branch: "main")
        )
        #expect(child == [.branch("main")])
    }

    @Test func aGrandchildComparesAgainstItsOwnParent() {
        let lines = TaskRowDetails.lines(agents: [
            agent("Parent", "/Users/me/Plume", branch: "main"),
            agent("Child", "/Users/me/Other", branch: "dev", depth: 1),
            agent("Grandchild", "/Users/me/Other", branch: "dev", depth: 2),
        ])
        #expect(headers(lines) == ["Parent", "Child", "Grandchild"])
        #expect(parentLabels(lines) == [nil, "Parent", "Child"])
        #expect(lines.last.map { if case .agentHeader = $0 { true } else { false } } == true)
    }

    @Test func severalTopLevelAgentsNestTheirChildrenWithTheTaskLevelLinesHoisted() {
        let lines = TaskRowDetails.lines(agents: [
            agent("One", "/Users/me/Plume", branch: "main"),
            agent("Child", "/Users/me/Plume", branch: "main", depth: 1),
            agent("Two", "/Users/me/Plume", branch: "main"),
        ])
        #expect(headers(lines) == ["One", "Child", "Two"])
        #expect(parentLabels(lines) == [nil, "One", nil])
        // Project and branch are shared by both top-level agents, so they sit
        // at the task level and the child, matching its parent, shows nothing.
        #expect(lines.count == 5)
        #expect(TaskRowDetails.agentGroupNesting(lines) == [[], [], [2], [2, 3], [4]])
    }

    @Test func childrenDoNotStopTopLevelAgentsSharingLines() {
        let lines = TaskRowDetails.lines(agents: [
            agent("One", "/Users/me/Plume", branch: "main"),
            agent("Child", "/Users/me/Elsewhere", branch: "other", depth: 1),
            agent("Two", "/Users/me/Plume", branch: "main"),
        ])
        #expect(Array(lines.prefix(2)) == [.project("Plume"), .branch("main")])
    }

    @Test func plainTopLevelAgentsTakeNoParentLabel() {
        let lines = TaskRowDetails.lines(agents: [agent("One", nil), agent("Two", nil)])
        #expect(parentLabels(lines) == [nil, nil])
        #expect(headers(lines) == ["One", "Two"])
    }

    @Test func activityFollowsItsAgentsOwnLinesBeforeItsChildren() {
        let one = UUID(), child = UUID()
        let lines = TaskRowDetails.lines(
            agents: [
                agent("One", "/Users/me/Plume", branch: "main", id: one),
                agent("Child", "/Users/me/Plume", branch: "fix", depth: 1, id: child),
                agent("Two", "/Users/me/Plume", branch: "dev"),
            ],
            activity: [one, child]
        )
        // The shared project sits first, at the task level.
        #expect(lines[3] == .activity(tabID: one))
        #expect(lines[6] == .activity(tabID: child))
        let nesting = TaskRowDetails.agentGroupNesting(lines)
        #expect(TaskRowDetails.agentTabTargets(lines, nesting: nesting)[6] == child)
    }

    @Test func aSoleTopLevelAgentsActivityFollowsItsOwnHeader() {
        let parent = UUID()
        let lines = TaskRowDetails.lines(
            agents: [agent("Parent", nil, id: parent), agent("Child", nil, depth: 1)],
            activity: [parent]
        )
        #expect(lines[1] == .activity(tabID: parent))
    }

    @Test func foldingKeepsEachHeadersLinesWithIt() {
        let two = UUID()
        let lines: [TaskRowDetails.Line] = [
            .project("Plume"),
            .agentHeader(TaskRowDetails.AgentHeader(tabID: UUID(), title: "One", status: .working)),
            .branch("one"),
            .agentHeader(TaskRowDetails.AgentHeader(tabID: two, title: "Two", status: .working)),
            .branch("two"),
            .activity(tabID: two),
        ]
        #expect(TaskRowDetails.lines(lines, keepingHeaders: 1) == (Array(lines.prefix(3)), [two]))
        #expect(TaskRowDetails.lines(lines, keepingHeaders: 2) == (lines, []))
        #expect(TaskRowDetails.headerCount(lines) == 2)
    }

    @Test func foldingKeepsTheFocusedAgentAndItsParents() {
        let focused = UUID()
        func header(_ title: String, depth: Int = 0, id: UUID = UUID()) -> TaskRowDetails.Line {
            .agentHeader(TaskRowDetails.AgentHeader(tabID: id, title: title, status: .working, depth: depth))
        }
        let lines: [TaskRowDetails.Line] = [
            header("1"), header("2"), header("3"), header("4"),
            header("5"),
            header("6"),
            header("6a", depth: 1, id: focused),
            .branch("fix"),
            header("7"),
        ]
        let folded = AgentRowCap.fold(lines, isExpanded: false, focusedTabID: focused)
        #expect(folded.lines == Array(lines.prefix(4)) + Array(lines[5...7]))
        #expect(folded.layout == AgentRowCap.Layout(visibleCount: 6, toggleTitle: "Show 2 more", toggleSymbol: "chevron.down"))
        #expect(folded.hiddenTabIDs.count == 2)
        let expanded = AgentRowCap.fold(lines, isExpanded: true, focusedTabID: focused)
        #expect(expanded.lines == lines)
        #expect(expanded.hiddenTabIDs.isEmpty)
    }

    @Test func aFocusedAgentThatWouldBeTheOnlyHiddenOneLeavesNoToggle() {
        let focused = UUID()
        let lines: [TaskRowDetails.Line] = (1...4).map {
            .agentHeader(TaskRowDetails.AgentHeader(tabID: UUID(), title: "\($0)", status: .working))
        } + [.agentHeader(TaskRowDetails.AgentHeader(tabID: focused, title: "5", status: .working))]
        let folded = AgentRowCap.fold(lines, isExpanded: false, focusedTabID: focused)
        #expect(folded.lines == lines)
        #expect(folded.layout.toggleTitle == nil)
    }

    @Test func anExpandedRowOffersShowFewerOnlyWhenCollapsingWouldHideSomething() {
        let focused = UUID()
        let lines: [TaskRowDetails.Line] = (1...4).map {
            .agentHeader(TaskRowDetails.AgentHeader(tabID: UUID(), title: "\($0)", status: .working))
        } + [.agentHeader(TaskRowDetails.AgentHeader(tabID: focused, title: "5", status: .working))]
        let keepsAll = AgentRowCap.fold(lines, isExpanded: true, focusedTabID: focused)
        #expect(keepsAll.layout.toggleTitle == nil)
        let hidesOne = AgentRowCap.fold(lines, isExpanded: true, focusedTabID: nil)
        #expect(hidesOne.layout == AgentRowCap.Layout(visibleCount: 5, toggleTitle: "Show fewer", toggleSymbol: "chevron.up"))
    }

    @Test func aChildsValueNamesItsParent() {
        let header = TaskRowDetails.AgentHeader(tabID: UUID(), title: "fix", status: .awaitingReply, parentLabel: "Parent")
        #expect(header.controlValue(isFocused: false, isHovered: false) == "\(header.statusText); child of Parent")
    }

    @Test func aHeaderNeedsAttentionWhenItsStatusWantsTheUserOrItIsUnread() {
        for status in TaskStatus.allCases {
            let header = TaskRowDetails.AgentHeader(tabID: UUID(), title: "Chat", status: status)
            let expected: Bool = switch status {
            case .permissionNeeded, .questionAsked, .planApproval, .needsTerminalInput: true
            default: false
            }
            #expect(header.needsAttention == expected, "\(status)")
        }
        let unread = TaskRowDetails.AgentHeader(tabID: UUID(), title: "Chat", status: .done, isUnread: true)
        #expect(unread.needsAttention)
        #expect(unread.controlValue(isFocused: false, isHovered: false) == "\(unread.statusText); attention")
    }
}

@MainActor
struct AgentRowCapTests {
    @Test func fourHeadersFit() {
        #expect(AgentRowCap.layout(total: 4, isExpanded: false)
            == AgentRowCap.Layout(visibleCount: 4, toggleTitle: nil, toggleSymbol: nil))
    }

    @Test func theTogglesValueAddsHover() {
        #expect(AgentRowCap.toggleValue(isExpanded: false, isHovered: false) == "collapsed")
        #expect(AgentRowCap.toggleValue(isExpanded: false, isHovered: true) == "collapsed; hovered")
        #expect(AgentRowCap.toggleValue(isExpanded: true, isHovered: true) == "expanded; hovered")
    }

    @Test func aFifthFoldsBehindAToggle() {
        #expect(AgentRowCap.layout(total: 6, isExpanded: false)
            == AgentRowCap.Layout(visibleCount: 4, toggleTitle: "Show 2 more", toggleSymbol: "chevron.down"))
        #expect(AgentRowCap.layout(total: 6, isExpanded: true)
            == AgentRowCap.Layout(visibleCount: 6, toggleTitle: "Show fewer", toggleSymbol: "chevron.up"))
    }
}

/// With one top-level agent, the task's title and a click on its row both
/// follow that agent rather than whichever child was last focused.
@MainActor
struct TaskRowChildSelectionTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    @Test func theTopLevelAgentNamesTheTaskWhenAChildIsFocused() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TaskStore.selectTab(child, in: task)

        let store = TitleStore()
        store.setTitle("Parent work", forTab: parent.id, source: .reply)
        store.setTitle("Child work", forTab: child.id, source: .reply)

        #expect(store.displayTitle(for: task) == "Parent work")
    }

    @Test func anUntitledTopLevelAgentLeavesTheTitleToTheFocusedChild() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TaskStore.selectTab(child, in: task)

        let store = TitleStore()
        store.setTitle("Child work", forTab: child.id, source: .reply)

        #expect(store.displayTitle(for: task) == "Child work")
    }

    @Test func oneAgentWithNoChildrenKeepsTheOldTitleRule() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = try #require(task.tabs.first)
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.selectTab(terminal, in: task)
        task.lastFocusedAgentTabID = nil

        let store = TitleStore()
        store.setTitle("Agent work", forTab: agent.id, source: .reply)
        store.setTitle("vim", forTab: terminal.id, source: .reply)

        #expect(store.displayTitle(for: task) == "vim")
    }

    @Test func severalTopLevelAgentsKeepTheLastFocusedTitle() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = try #require(task.tabs.first)
        let second = TaskStore.addTab(to: task, kind: .agent, in: context)
        TaskStore.selectTab(second, in: task)

        let store = TitleStore()
        store.setTitle("First", forTab: first.id, source: .reply)
        store.setTitle("Second", forTab: second.id, source: .reply)

        #expect(store.displayTitle(for: task) == "Second")
    }

    @Test func aRowClickSelectsTheTopLevelAgentOverAChild() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TaskStore.selectTab(child, in: task)

        TaskStore.selectRowClickTab(of: task)
        #expect(task.selectedTabID == parent.id)
    }

    @Test func aRowClickLeavesATerminalSelected() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        _ = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.selectTab(terminal, in: task)

        #expect(TaskStore.rowClickTab(of: task) == nil)
    }

    @Test func aRowClickWithSeveralTopLevelAgentsChangesNothing() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = try #require(task.tabs.first)
        _ = TaskStore.addChildTab(to: task, parent: first, in: context)
        let second = TaskStore.addTab(to: task, kind: .agent, in: context)
        TaskStore.selectTab(second, in: task)

        #expect(TaskStore.rowClickTab(of: task) == nil)
    }

    @Test func aRowClickWithNoChildrenChangesNothing() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.selectTab(terminal, in: task)

        #expect(TaskStore.rowClickTab(of: task) == nil)
    }
}
