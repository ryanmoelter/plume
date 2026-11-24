import AppKit
import Foundation
import Testing

@testable import Plume

/// The params of `scrollTo`, `menu.*` and `sidebar.width`: each request
/// decodes to one destination or is refused with a message naming the
/// problem, and `menu.pick` resolves an item by path, then title, then
/// substring.
@MainActor
struct ControlNavigationTests {
    private func decode(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlServerRequest.self, from: Data(json.utf8)).command
    }

    private func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    @Test func scrollToTakesExactlyOneDestination() throws {
        let control = ControlTarget.control(id: "x", index: nil, label: nil)
        #expect(try ScrollToParams(target: control).destination() == .control(control))
        #expect(try ScrollToParams(edge: "top").destination() == .top)
        #expect(try ScrollToParams(edge: "bottom", within: control).destination() == .bottom)
        #expect(try ScrollToParams(offset: 120).destination() == .offset(120))
        #expect(try ScrollToParams(by: -40, within: .chatList).destination() == .by(-40))

        #expect(message { _ = try ScrollToParams().destination() }?.contains("needs a target, an edge, an offset or by") == true)
        #expect(message { _ = try ScrollToParams(edge: "top", offset: 3).destination() }?.contains("one of") == true)
        #expect(message { _ = try ScrollToParams(edge: "middle").destination() }?.contains("top or bottom") == true)
        #expect(message { _ = try ScrollToParams(target: control, within: .chatList).destination() }?.contains("within") == true)
    }

    @Test func scrollToDecodesOffsetAndWithin() throws {
        guard case .scrollTo(let params) = try decode(#"{"id":"1","command":"scrollTo","offset":500,"within":{"id":"info-pane"}}"#) else {
            Issue.record("not scrollTo"); return
        }
        #expect(params.offset == 500)
        #expect(params.within == .control(id: "info-pane", index: nil, label: nil))
    }

    @Test func menuOpenTakesATargetOrAPoint() throws {
        try MenuOpenParams(target: .control(id: "x", index: nil, label: nil)).validate()
        try MenuOpenParams(x: 10, y: 20).validate()
        #expect(message { try MenuOpenParams().validate() }?.contains("needs a target") == true)
        #expect(message { try MenuOpenParams(x: 10).validate() }?.contains("needs a target") == true)
        #expect(message { try MenuOpenParams(target: .composer, x: 1, y: 2).validate() }?.contains("not both") == true)

        guard case .openMenu(let decoded) = try decode(#"{"id":"1","command":"menu.open","x":5,"y":6}"#) else {
            Issue.record("not menu.open"); return
        }
        #expect(decoded == MenuOpenParams(x: 5, y: 6, timeout: 2))
    }

    @Test func menuPickPrefersAnExactPathThenATitleThenASubstring() throws {
        let paths = ["Copy", "Copy Link", "Sort > Newest", "Sort > Oldest", "Open in Browser"]
        #expect(try PopupMenuItemMatch.index(of: "Copy", in: paths) == 0)
        #expect(try PopupMenuItemMatch.index(of: "Newest", in: paths) == 2)
        #expect(try PopupMenuItemMatch.index(of: "Sort > Oldest", in: paths) == 3)
        #expect(try PopupMenuItemMatch.index(of: "browser", in: paths) == 4)
        #expect(message { _ = try PopupMenuItemMatch.index(of: "sort", in: paths) }?.contains("2 controls match") == true)
        #expect(message { _ = try PopupMenuItemMatch.index(of: "Paste", in: paths) }?.contains("not found") == true)
    }

    @Test func sidebarWidthDecodesAnOptionalWidth() throws {
        guard case .sidebarWidth(let read) = try decode(#"{"id":"1","command":"sidebar.width"}"#),
              case .sidebarWidth(let set) = try decode(#"{"id":"2","command":"sidebar.width","width":300,"expand":true}"#)
        else { Issue.record("not sidebar.width"); return }
        #expect(read.width == nil)
        #expect(read.expand == nil)
        #expect(set.width == 300)
        #expect(set.expand == true)
    }

    @Test func sidebarSplitReadsACollapsedSidebarAsZero() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        split.isVertical = true
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(NSView(frame: NSRect(x: 241, y: 0, width: 559, height: 400)))
        window.contentView = split
        split.adjustSubviews()
        split.setPosition(240, ofDividerAt: 0)

        let shown = SidebarSplit.width(in: window)
        #expect(shown?.isCollapsed == false)
        #expect(shown?.width == 240)

        sidebar.isHidden = true
        #expect(SidebarSplit.width(in: window)?.isCollapsed == true)
        #expect(SidebarSplit.width(in: window)?.width == 0)
    }
}
