import AppKit
import Testing

@testable import Plume

/// `SyntheticDrag` replays the `NSDraggingDestination` protocol against a
/// real view and reports which step ended it, so a drop that highlights and
/// then does nothing is distinguishable from one that was never offered.
@MainActor
struct SyntheticDragTests {
    /// Records the handshake and answers each step from what the test set.
    private final class RecordingDestination: NSView {
        var enteredOperation: NSDragOperation = .copy
        var prepares = true
        var performs = true
        private(set) var steps: [String] = []

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            steps.append("entered")
            return enteredOperation
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            steps.append("updated")
            return enteredOperation
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            steps.append("prepare")
            return prepares
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            steps.append("perform")
            return performs
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            steps.append("conclude")
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            steps.append("exited")
        }
    }

    private func info(text: String = "payload") -> SyntheticDraggingInfo {
        let pasteboard = SyntheticDraggingInfo.makePasteboard()
        pasteboard.setString(text, forType: .string)
        return SyntheticDraggingInfo(pasteboard: pasteboard, location: .zero, window: nil)
    }

    @Test func aDropThatLandsRunsEveryStep() {
        let view = RecordingDestination()
        let outcome = SyntheticDrag.perform(info(), on: view)
        #expect(outcome.succeeded)
        #expect(outcome.refusedAt == nil)
        #expect(view.steps == ["entered", "updated", "prepare", "perform", "conclude"])
    }

    @Test func refusingToPrepareStopsBeforeTheDropAndIsNamed() {
        let view = RecordingDestination()
        view.prepares = false
        let outcome = SyntheticDrag.perform(info(), on: view)
        #expect(!outcome.succeeded)
        #expect(outcome.refusedAt == "prepareForDragOperation")
        #expect(!view.steps.contains("perform"))
    }

    @Test func anEmptyOperationOnEntryNeverReachesTheDrop() {
        let view = RecordingDestination()
        view.enteredOperation = []
        let outcome = SyntheticDrag.perform(info(), on: view)
        #expect(outcome.refusedAt == "draggingEntered")
        #expect(view.steps == ["entered", "exited"])
    }

    @Test func performingAndReturningFalseIsNamedSeparatelyFromRefusingToPrepare() {
        let view = RecordingDestination()
        view.performs = false
        let outcome = SyntheticDrag.perform(info(), on: view)
        #expect(outcome.refusedAt == "performDragOperation")
        #expect(!view.steps.contains("conclude"))
    }

    /// The bug this whole facility exists to catch: SwiftUI registers
    /// `public.data`, and matching the offered type literally finds nothing.
    @Test func aDestinationRegisteredForASupertypeAcceptsTheOfferedType() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = RecordingDestination(frame: .init(x: 0, y: 0, width: 100, height: 100))
        view.registerForDraggedTypes([.init("public.data")])
        window.contentView?.addSubview(view)

        let found = SyntheticDrag.destination(at: .init(x: 50, y: 50), in: window, types: [.string])
        #expect(found === view)
    }

    @Test func aDestinationIsFoundThoughHitTestingNeverReachesIt() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = RecordingDestination(frame: .init(x: 0, y: 0, width: 100, height: 100))
        view.registerForDraggedTypes([.string])
        window.contentView?.addSubview(view)
        // In front of the destination and opaque to hit testing, the way
        // SwiftUI draws its content over its drop region.
        let cover = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(cover)

        #expect(window.contentView?.hitTest(.init(x: 50, y: 50)) === cover)
        #expect(SyntheticDrag.destination(at: .init(x: 50, y: 50), in: window, types: [.string]) === view)
    }

    @Test func surveyingTheWindowListsEveryDestinationWithItsTypes() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = RecordingDestination(frame: .init(x: 0, y: 0, width: 100, height: 100))
        view.registerForDraggedTypes([.fileURL])
        window.contentView?.addSubview(view)
        window.contentView?.addSubview(NSView(frame: .init(x: 0, y: 0, width: 10, height: 10)))

        let destinations = SyntheticDrag.allDestinations(in: window)
        #expect(destinations.count == 1)
        #expect(destinations.first?.types == [NSPasteboard.PasteboardType.fileURL.rawValue])
    }
}
