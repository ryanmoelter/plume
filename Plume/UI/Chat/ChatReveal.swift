import AppKit
import SwiftUI

/// How far an assistant message's reveal has reached, as a character index
/// that runs on a spring toward the characters received so far.
///
/// Every `Text` of the message lays out everything received the moment it
/// arrives; the reveal only decides each word's opacity at draw time. A word
/// starts fading in when the index reaches it, so a long word holds the next
/// one back for longer while the pace in characters stays even.
///
/// Positions count UTF-16 units, which is what `Text.Layout.CharacterIndex`
/// counts.
@MainActor
@Observable
final class MessageReveal {
    /// Read only by a `Text` the reveal is passing through, so one frame
    /// redraws one or two `Text`s rather than the whole message.
    private(set) var position: Double
    /// The clock of the latest frame, advanced only while a word is still
    /// fading on `RevealTuning.Values.fadeDuration`.
    private(set) var time: CFTimeInterval = 0
    @ObservationIgnored fileprivate(set) var target: Double
    @ObservationIgnored fileprivate var velocity: Double = 0
    /// Where the reveal stood when, over the last fade duration, so a word
    /// can find the moment the reveal reached it.
    @ObservationIgnored private(set) var samples: [RevealSample] = []
    /// Where the reveal stood one fade duration ago: every word before it has
    /// finished its timed fade.
    @ObservationIgnored private(set) var faded: Double
    /// Content ahead of or behind the reveal observes only its own span, so
    /// a frame re-renders just the spans whose phase it changes.
    @ObservationIgnored private var spans: [SpanKey: RevealSpan] = [:]

    init(position: Double, target: Double) {
        self.position = position
        self.faded = position
        self.target = target
    }

    var isSettled: Bool { position >= target }
    var isFading: Bool { faded < position }

    fileprivate func record(_ newPosition: Double, at now: CFTimeInterval, previous: CFTimeInterval, fadeDuration: Double) {
        if newPosition != position {
            if samples.isEmpty { samples.append(RevealSample(time: previous, position: position)) }
            samples.append(RevealSample(time: now, position: newPosition))
            position = newPosition
        }
        let cutoff = now - fadeDuration
        // One sample at or before the cutoff stays, to interpolate from.
        while samples.count > 1, samples[1].time <= cutoff { samples.removeFirst() }
        faded = fadeDuration > 0 ? RevealSample.position(at: cutoff, in: samples, current: position) : position
        if faded >= position { samples.removeAll() }
        if isFading { time = now }
        updateSpans()
    }

    fileprivate func settle() {
        velocity = 0
        samples.removeAll()
        if target != position { position = target }
        faded = target
        updateSpans()
    }

    private func updateSpans() {
        for (key, span) in spans {
            let phase = phase(across: key.start, key.end)
            if span.phase != phase { span.phase = phase }
        }
    }

    private func phase(across start: Double, _ end: Double) -> RevealSpan.Phase {
        // Non-text pieces (tool calls, thinking, notices) use a zero-width
        // gate at their reveal offset. There is no character span for the
        // ordinary `faded >= end` check to cross, so show that boundary once
        // the reveal reaches it. A normal span still follows its end, even
        // when its start happens to be beyond the current target.
        if start == end && position >= start { return .shown }
        if faded >= end { return .shown }
        if position <= start { return .hidden }
        return .partial
    }

    /// The span's phase, observed on its own. Created on first read.
    func span(across start: Double, _ end: Double) -> RevealSpan {
        let key = SpanKey(start: start, end: end)
        if let span = spans[key] { return span }
        let span = RevealSpan(phase: phase(across: start, end))
        spans[key] = span
        return span
    }

    private struct SpanKey: Hashable {
        var start: Double
        var end: Double
    }

    enum State {
        case shown
        case hidden
        case partial(RevealFrame)
    }

    /// The reveal as seen by content spanning `start..<end`. Only content the
    /// reveal is inside reads the per-frame values.
    func state(across start: Double, _ end: Double) -> State {
        switch span(across: start, end).phase {
        case .shown: .shown
        case .hidden: .hidden
        case .partial: .partial(RevealFrame(position: position, time: time, faded: faded, samples: samples))
        }
    }
}

/// Where one stretch of a message stands against its reveal.
@MainActor
@Observable
final class RevealSpan {
    enum Phase {
        case hidden
        case partial
        case shown
    }

    fileprivate(set) var phase: Phase

    fileprivate init(phase: Phase) {
        self.phase = phase
    }
}

struct RevealSample: Equatable {
    var time: CFTimeInterval
    var position: Double

    /// Where the reveal stood at `time`, interpolating between samples.
    static func position(at time: CFTimeInterval, in samples: [RevealSample], current: Double) -> Double {
        guard let first = samples.first else { return current }
        if time <= first.time { return first.position }
        guard let next = samples.firstIndex(where: { $0.time > time }) else { return current }
        let a = samples[next - 1], b = samples[next]
        return a.position + (b.position - a.position) * (time - a.time) / (b.time - a.time)
    }

    /// When the reveal reached `position`: minus infinity for a position it
    /// passed before the samples begin, plus infinity for one not yet reached.
    static func time(reaching position: Double, in samples: [RevealSample]) -> CFTimeInterval {
        guard let first = samples.first, position > first.position else { return -.infinity }
        guard let next = samples.firstIndex(where: { $0.position >= position }) else { return .infinity }
        let a = samples[next - 1], b = samples[next]
        return a.time + (b.time - a.time) * (position - a.position) / (b.position - a.position)
    }
}

/// One frame of a reveal, as a `Text` under it draws it.
struct RevealFrame {
    var position: Double
    var time: CFTimeInterval
    var faded: Double
    var samples: [RevealSample]
}

/// A damped spring pulling the reveal toward the text received so far. Its
/// pull grows with the distance left, so the reveal speeds up when it falls
/// behind and eases in as it catches up, with velocity continuous through
/// every retarget.
struct RevealSpring {
    var position: Double
    var velocity: Double

    mutating func step(toward target: Double, by interval: Double, tuning: RevealTuning.Values) {
        guard position < target else {
            position = target
            velocity = 0
            return
        }
        let omega = 2 * Double.pi / tuning.response
        let stiffness = omega * omega
        let damping = 2 * tuning.dampingRatio * omega
        var remaining = interval
        while remaining > 0 {
            let step = min(remaining, 1.0 / 240)
            remaining -= step
            velocity += (stiffness * (target - position) - damping * velocity) * step
            // A reveal never runs backwards, and never idles short of text
            // it already has.
            velocity = max(velocity, tuning.minimumSpeed)
            if tuning.maximumSpeed > 0 { velocity = min(velocity, tuning.maximumSpeed) }
            position += velocity * step
            if position >= target {
                position = target
                velocity = 0
                return
            }
        }
    }
}

/// One chat's reveals, keyed by message id, and the display link that moves
/// them.
///
/// Per tab and outliving the chat's views, which are unmounted while their
/// tab is hidden: a tab switched back to mid-reply carries on from where the
/// reveal had got to rather than replaying it.
@MainActor
final class ChatRevealModel: NSObject {
    private static var models: [UUID: ChatRevealModel] = [:]

    static func shared(for tabID: UUID) -> ChatRevealModel {
        if let model = models[tabID] { return model }
        let model = ChatRevealModel()
        models[tabID] = model
        return model
    }

    private var reveals: [String: MessageReveal] = [:]
    /// Set by the first update that carries any message. Everything that
    /// update holds is history and shows whole; only what arrives after it
    /// reveals.
    private var isPrimed = false
    private var displayLink: CADisplayLink?
    private var fallback: Timer?
    private var lastTimestamp: CFTimeInterval?

    func reveal(for messageID: String) -> MessageReveal? {
        reveals[messageID]
    }

    /// Whether the reveal has reached where `piece` starts. The working
    /// indicator and anything outside an assistant message always has.
    func hasReached(_ piece: ChatPiece) -> Bool {
        guard piece.role == .assistant, piece.content != .working, piece.revealOffset > 0,
              let reveal = reveals[piece.messageID] else { return true }
        return reveal.position >= Double(piece.revealOffset)
    }

    /// Where each message the reveal has yet to finish is headed.
    var unsettledTargets: [String: Double] {
        reveals.compactMapValues { $0.isSettled ? nil : $0.target }
    }

    /// Calls `action` once the reveal of any listed message reaches its
    /// position, replacing whatever was watched before.
    func watch(_ thresholds: [String: Double], action: @escaping () -> Void) {
        self.thresholds = thresholds
        onReach = thresholds.isEmpty ? nil : action
    }

    private var thresholds: [String: Double] = [:]
    private var onReach: (() -> Void)?

    private func fireReachedThresholds() {
        guard let onReach else { return }
        let reached = thresholds.contains { id, threshold in
            (reveals[id]?.position ?? .infinity) >= threshold
        }
        guard reached else { return }
        thresholds = [:]
        self.onReach = nil
        onReach()
    }

    /// Retargets each message at `length` characters, and forgets any
    /// message no longer listed.
    func update(targets: [(messageID: String, length: Int)]) {
        let animates = isPrimed && AppSettings.shared.animateCharacterReveal
        // A stream that never named its message, taken over by the
        // transcript's copy under a real id.
        var unclaimed = reveals[ChatStreamHandoff.unidentifiedLiveID]
        if targets.contains(where: { $0.messageID == ChatStreamHandoff.unidentifiedLiveID }) { unclaimed = nil }

        var next: [String: MessageReveal] = [:]
        for (id, length) in targets {
            let target = Double(length)
            let reveal: MessageReveal
            if let existing = reveals[id] {
                reveal = existing
            } else if let claimed = unclaimed {
                reveal = claimed
                unclaimed = nil
            } else {
                reveal = MessageReveal(position: animates ? 0 : target, target: target)
            }
            reveal.target = target
            if !animates || reveal.position > target { reveal.settle() }
            next[id] = reveal
        }
        reveals = next
        if !targets.isEmpty { isPrimed = true }
        if reveals.values.contains(where: { !$0.isSettled || $0.isFading }) { resume() }
    }

    func advance(by interval: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        let tuning = RevealTuning.shared.values
        let animates = AppSettings.shared.animateCharacterReveal
        var isMoving = false
        for reveal in reveals.values where !reveal.isSettled || reveal.isFading {
            if animates {
                var spring = RevealSpring(position: reveal.position, velocity: reveal.velocity)
                spring.step(toward: reveal.target, by: interval, tuning: tuning)
                reveal.velocity = spring.velocity
                reveal.record(spring.position, at: now, previous: now - interval, fadeDuration: tuning.fadeDuration)
            } else {
                reveal.settle()
            }
            isMoving = isMoving || !reveal.isSettled || reveal.isFading
        }
        fireReachedThresholds()
        if !isMoving { pause() }
    }

    private func resume() {
        if displayLink == nil, let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if let displayLink {
            let rate = Float(RevealTuning.shared.values.frameRate)
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 30), maximum: rate, preferred: rate)
            displayLink.isPaused = false
        } else if fallback == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(at: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallback = timer
        }
    }

    private func pause() {
        displayLink?.isPaused = true
        fallback?.invalidate()
        fallback = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        tick(at: link.targetTimestamp)
    }

    private func tick(at now: CFTimeInterval) {
        // Capped, so a stall reads as a slow frame rather than a leap.
        let interval = min(lastTimestamp.map { now - $0 } ?? 1.0 / 60, 1.0 / 20)
        lastTimestamp = now
        advance(by: max(interval, 0), now: now)
    }
}

/// The knobs of the reveal. A debug build persists them and exposes them in
/// Settings so the feel can be tuned by eye; a release build always uses
/// `Values.defaults`.
@MainActor
@Observable
final class RevealTuning {
    static let shared = RevealTuning()

    struct Values: Equatable {
        /// Seconds for the spring's undamped period: lower chases the text
        /// harder.
        var response: Double
        /// 1 is critically damped; lower lets the pace surge and ease.
        var dampingRatio: Double
        /// Characters per second the reveal never drops below while behind.
        var minimumSpeed: Double
        /// Characters per second it never exceeds. Zero is no limit.
        var maximumSpeed: Double
        /// Seconds a word takes to fade in from the moment the reveal
        /// reaches it. Zero makes each word appear at once.
        var fadeDuration: Double
        /// Frames per second the reveal draws at, at most. Each frame
        /// re-renders the words mid-fade, so this trades smoothness for CPU.
        var frameRate: Double

        static let defaults = Values(
            response: 0.3,
            dampingRatio: 1,
            minimumSpeed: 1,
            maximumSpeed: 0,
            fadeDuration: 0.3,
            frameRate: 60
        )
    }

    static let responseRange: ClosedRange<Double> = 0.05...3
    static let dampingRatioRange: ClosedRange<Double> = 0.2...3
    static let minimumSpeedRange: ClosedRange<Double> = 1...400
    static let maximumSpeedRange: ClosedRange<Double> = 0...3000
    static let fadeDurationRange: ClosedRange<Double> = 0...2
    static let frameRateRange: ClosedRange<Double> = 20...120

    var values: Values {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private static let key = "revealTuning"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        #else
        let stored: [String: Double] = [:]
        #endif
        let fallback = Values.defaults
        values = Values(
            response: stored["response"] ?? fallback.response,
            dampingRatio: stored["dampingRatio"] ?? fallback.dampingRatio,
            minimumSpeed: stored["minimumSpeed"] ?? fallback.minimumSpeed,
            maximumSpeed: stored["maximumSpeed"] ?? fallback.maximumSpeed,
            fadeDuration: stored["fadeDuration"] ?? fallback.fadeDuration,
            frameRate: stored["frameRate"] ?? fallback.frameRate
        )
    }

    func reset() {
        values = .defaults
    }

    private func save() {
        defaults.set([
            "response": values.response,
            "dampingRatio": values.dampingRatio,
            "minimumSpeed": values.minimumSpeed,
            "maximumSpeed": values.maximumSpeed,
            "fadeDuration": values.fadeDuration,
            "frameRate": values.frameRate
        ], forKey: Self.key)
    }
}

/// Draws a `Text` with each word fading in over a fixed time from the moment
/// the reveal reaches it. The reveal's pace decides when each word starts, so
/// a long word still holds the next one back for longer.
///
/// Runs whose words have all finished fading draw in one call and runs the
/// reveal has not reached are skipped, so only the words mid-fade are drawn a
/// glyph at a time.
struct WordReveal: TextRenderer {
    /// The reveal position relative to this `Text`'s first character.
    var position: Double
    /// Where each word starts, ascending and beginning at zero. A word runs
    /// to the next start, so it carries its trailing space and punctuation.
    var wordStarts: [Int]
    var length: Int
    /// Nil shows each word whole the moment the reveal reaches it.
    var timing: Timing?

    struct Timing {
        /// Where this `Text` starts along the message's reveal.
        var offset: Double
        var frame: RevealFrame
        var duration: Double
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        guard position.isFinite else {
            if position > 0 { layout.forEach { ctx.draw($0) } }
            return
        }
        guard let origin = layout.first?.first?.characterIndices.first else { return }
        let fadedThrough = timing.map { $0.frame.faded - $0.offset } ?? position
        for line in layout {
            for run in line {
                guard let first = run.characterIndices.first, let last = run.characterIndices.last else { continue }
                let firstIndex = origin.distance(to: first)
                if fadedThrough >= Double(origin.distance(to: last) + 1) {
                    ctx.draw(run)
                    continue
                }
                if position <= Double(Self.word(containing: firstIndex, in: wordStarts, length: length).lowerBound) {
                    continue
                }
                for slice in run {
                    guard let index = slice.characterIndices.first else { continue }
                    let opacity = opacity(at: origin.distance(to: index))
                    guard opacity > 0 else { continue }
                    var glyph = ctx
                    glyph.opacity = opacity
                    glyph.draw(slice)
                }
            }
        }
    }

    func opacity(at index: Int) -> Double {
        let start = Double(Self.word(containing: index, in: wordStarts, length: length).lowerBound)
        guard position > start else { return 0 }
        guard let timing, timing.duration > 0 else { return 1 }
        let reached = RevealSample.time(reaching: timing.offset + start, in: timing.frame.samples)
        guard reached.isFinite else { return reached < 0 ? 1 : 0 }
        return min(1, max(0, (timing.frame.time - reached) / timing.duration))
    }

    /// The word holding `index`: from its start to the next word's.
    static func word(containing index: Int, in starts: [Int], length: Int) -> Range<Int> {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= index { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return index..<(index + 1) }
        let end = low < starts.count ? starts[low] : max(length, index + 1)
        return starts[low - 1]..<end
    }

    /// Where each word of `text` starts in UTF-16 units, always beginning at
    /// zero so leading punctuation belongs to the first word.
    static func wordStarts(in text: String) -> [Int] {
        if let cached = wordStartCache[text] { return cached }
        var starts: [Int] = [0]
        let string = text as NSString
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            if range.location > 0 { starts.append(range.location) }
        }
        if wordStartCache.count >= 256 { wordStartCache.removeAll(keepingCapacity: true) }
        wordStartCache[text] = starts
        return starts
    }

    /// Read on every frame a `Text` spends under the reveal.
    private static var wordStartCache: [String: [Int]] = [:]
}

/// The reveal a piece's `Text`s read, and where the one reading it starts.
struct ChatRevealContext: Equatable {
    let reveal: MessageReveal
    var offset: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reveal === rhs.reveal && lhs.offset == rhs.offset
    }
}

extension EnvironmentValues {
    /// Nil everywhere but an assistant message's prose and code.
    @Entry var chatReveal: ChatRevealContext?
    @Entry var chatRevealModel: ChatRevealModel?
}

extension View {
    /// Shifts the reveal so the `Text`s below count from `offset`
    /// characters further in.
    func chatRevealOffset(_ offset: Int) -> some View {
        transformEnvironment(\.chatReveal) { $0?.offset += offset }
    }

    /// Fades this `Text`, which draws `text`, in behind the reveal.
    func revealFade(_ text: AttributedString) -> some View {
        modifier(RevealFade(text: String(text.characters)))
    }

    func revealFade(_ text: String) -> some View {
        modifier(RevealFade(text: text))
    }

    /// Hides content that is not `Text` until the reveal reaches it.
    func revealGate(_ context: ChatRevealContext?) -> some View {
        modifier(RevealGate(context: context))
    }
}

private struct RevealFade: ViewModifier {
    let text: String
    @Environment(\.chatReveal) private var context
    @State private var tuning = RevealTuning.shared

    func body(content: Content) -> some View {
        if let context {
            let values = tuning.values
            let length = text.utf16.count
            let start = Double(context.offset)
            let end = start + Double(length)
            content.textRenderer(renderer(
                state: context.reveal.state(across: start, end),
                start: start,
                length: length,
                values: values
            ))
        } else {
            content
        }
    }

    private func renderer(state: MessageReveal.State, start: Double, length: Int, values: RevealTuning.Values) -> WordReveal {
        var renderer = WordReveal(
            position: 0,
            wordStarts: WordReveal.wordStarts(in: text),
            length: length
        )
        switch state {
        case .shown:
            renderer.position = .infinity
        case .hidden:
            renderer.position = -.infinity
        case let .partial(frame):
            renderer.position = frame.position - start
            renderer.timing = WordReveal.Timing(offset: start, frame: frame, duration: values.fadeDuration)
        }
        return renderer
    }
}

private struct RevealGate: ViewModifier {
    let context: ChatRevealContext?

    func body(content: Content) -> some View {
        let isShown: Bool = context.map { context in
            let offset = Double(context.offset)
            return context.reveal.span(across: offset, offset).phase != .hidden
        } ?? true
        content
            .opacity(isShown ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isShown)
    }
}

enum ChatReveal {
    /// The characters a piece puts along its message's reveal, or zero for
    /// one drawn by something other than `Text`, which the reveal passes
    /// through at a single point instead.
    static func length(of content: ChatPiece.Content) -> Int {
        switch content {
        case let .markdown(block, _): length(of: block)
        case let .codeSegment(segment): segment.isMermaid ? 0 : segment.code.utf16.count
        case let .listSegment(segment): segment.items.reduce(0) { $0 + length(of: $1.text) }
        case .thinking, .toolCall, .injected, .agentMessageTitle, .notice, .image, .working: 0
        }
    }

    static func length(of block: MarkdownBlock) -> Int {
        switch block {
        case let .paragraph(text), let .heading(_, text), let .quote(text, _):
            length(of: text)
        case let .list(items):
            items.reduce(0) { $0 + length(of: $1.text) }
        case let .codeBlock(language, code):
            MermaidDocument.isMermaidFence(language: language) ? 0 : code.utf16.count
        case let .table(header, _, rows):
            tableCells(header: header, rows: rows).reduce(0) { $0 + length(of: $1) }
        case .rule:
            0
        }
    }

    /// The characters of one inline run of markdown once rendered.
    ///
    /// Memoized apart from `MarkdownCache`: every rebuild asks this of every
    /// block in the transcript, which is more than that cache holds, so
    /// asking it would re-render the whole transcript's markdown per delta.
    static func length(of inlineMarkdown: String) -> Int {
        if let cached = inlineLengths[inlineMarkdown] { return cached }
        let length = String(MarkdownCache.inline(inlineMarkdown).characters).utf16.count
        if inlineLengths.count >= 8192 { inlineLengths.removeAll(keepingCapacity: true) }
        inlineLengths[inlineMarkdown] = length
        return length
    }

    private static var inlineLengths: [String: Int] = [:]

    /// Each message's reveal length: the sum of its pieces'. Every message is
    /// listed, so the first update that carries any marks them all as
    /// history.
    static func targets(of messages: [ChatMessage], pieces: [ChatPiece]) -> [(messageID: String, length: Int)] {
        var lengths: [String: Int] = [:]
        for piece in pieces { lengths[piece.messageID, default: 0] += piece.revealLength }
        return messages.map { ($0.id, lengths[$0.id] ?? 0) }
    }

    /// A table's cells in the order the reveal crosses them: row-major, each
    /// row padded to the widest, the header only when it says something.
    static func tableCells(header: [String], rows: [[String]]) -> [String] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let padded = { (row: [String]) in (0..<columnCount).map { row.indices.contains($0) ? row[$0] : "" } }
        let body = rows.flatMap(padded)
        return MarkdownBlock.headerIsMeaningful(header) ? padded(header) + body : body
    }

    /// Where each of `tableCells` starts along the table's reveal.
    static func tableCellOffsets(header: [String], rows: [[String]]) -> [Int] {
        var offset = 0
        return tableCells(header: header, rows: rows).map { cell in
            defer { offset += length(of: cell) }
            return offset
        }
    }
}
