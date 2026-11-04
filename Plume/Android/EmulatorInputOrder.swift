/// Keeps an emulator's input in the order it was sent while a paste is in flight. A paste waits on
/// the clipboard before its Control-V goes out, so anything sent after it, another paste included,
/// queues until it finishes. With no paste pending, input goes straight through.
nonisolated struct EmulatorInputOrder<Input: Sendable>: Sendable {
    enum Step: Sendable {
        case deliver(Input)
        case startPaste(String)
    }

    private enum Queued: Sendable {
        case input(Input)
        case paste(String)
    }

    private var isPasting = false
    private var queue: [Queued] = []

    mutating func input(_ input: Input) -> [Step] {
        guard isPasting else { return [.deliver(input)] }
        queue.append(.input(input))
        return []
    }

    mutating func paste(_ text: String) -> [Step] {
        guard isPasting else {
            isPasting = true
            return [.startPaste(text)]
        }
        queue.append(.paste(text))
        return []
    }

    /// Releases what queued behind the paste, up to and including the next paste, if any.
    mutating func pasteFinished() -> [Step] {
        var steps: [Step] = []
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case .input(let input):
                steps.append(.deliver(input))
            case .paste(let text):
                steps.append(.startPaste(text))
                return steps
            }
        }
        isPasting = false
        return steps
    }
}
