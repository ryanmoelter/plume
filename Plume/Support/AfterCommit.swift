import Foundation

/// Runs work once the current main-thread turn has committed its frame.
///
/// `DispatchQueue.main.async` alone is not enough: the run loop drains the
/// main queue before it commits, so the work lands in the same frame it was
/// meant to follow. An observer ordered after Core Animation's commit fires
/// once that frame is out, and queues the work for the next turn.
enum AfterCommit {
    static func perform(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in
            DispatchQueue.main.async { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
