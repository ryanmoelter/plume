import AppKit
import SwiftUI

/// The bar down the left of each agent group in a task row with several
/// agent tabs, at the weight of the info pane's bracket. A group's lines may
/// sit on either side of the row's status badge, so each line reports its
/// frame and the row draws every bar over the whole of itself.
enum AgentGroupBar {
    /// Clears the bar plus a small gap.
    static let indent: CGFloat = 6
    /// Keeps the bars of neighboring groups apart.
    static let endInset: CGFloat = 2
    /// Stronger than the info pane's divider tone, which vanishes over the
    /// selected row's wash.
    static let emphasis: Emphasis = .disabled
    /// How far past the row's own frame its bars may draw. The row clips to
    /// its frame, which would cut off a bar widening into the gutter.
    static let drawingOutset: CGFloat = hoveredWidth

    static let focusedWidth: CGFloat = 2
    static let pressedWidth: CGFloat = 2.5
    static let hoveredWidth: CGFloat = 4
    /// How far a pointer may travel with the button down before the press
    /// gives way to the row's drag.
    static let pressSlop: CGFloat = 3

    static func lineWidth(captionSize: CGFloat) -> CGFloat {
        InfoPaneBracketStub(pointSize: captionSize, centerX: 0).lineWidth
    }

    /// What one group's bar is showing.
    enum Look: Equatable {
        case normal
        case focused
        case hovered
        case pressed
    }

    static func look(ofGroup group: Int, focused: Int?, hovered: Int?, pressed: Int?) -> Look {
        if pressed == group { return .pressed }
        if hovered == group { return .hovered }
        return focused == group ? .focused : .normal
    }

    static func width(of look: Look, lineWidth: CGFloat) -> CGFloat {
        switch look {
        case .normal: lineWidth
        case .focused: max(lineWidth, focusedWidth)
        case .hovered: max(lineWidth, hoveredWidth)
        case .pressed: max(lineWidth, pressedWidth)
        }
    }

    /// A press snaps in; everything else, the release included, springs.
    static func animation(to look: Look) -> Animation {
        look == .pressed ? .easeOut(duration: 0.08) : .spring(duration: 0.28, bounce: 0.3)
    }

    static let fade = Animation.easeOut(duration: 0.15)

    /// A bar's color eases on its own curve: it changes with focus, which a
    /// hovered or pressed group's look does not show, and a spring's
    /// overshoot flashes a color past its target.
    static let colorFade = Animation.easeInOut(duration: 0.22)

    /// How a row draws its groups' bars, each group named by its header index.
    struct Style {
        var color: Color
        var lineWidth: CGFloat
        var looks: [Int: Look] = [:]
        /// Replaces `color` for a group's bar.
        var colors: [Int: Color] = [:]
    }
}

/// Every line of one agent group, keyed by the group's header index.
struct AgentGroupBarFrames: PreferenceKey {
    struct Group {
        /// How many groups this one sits inside.
        var level: Int
        var lines: [Anchor<CGRect>]
    }

    static let defaultValue: [Int: Group] = [:]

    static func reduce(value: inout [Int: Group], nextValue: () -> [Int: Group]) {
        value.merge(nextValue()) { existing, next in
            Group(level: existing.level, lines: existing.lines + next.lines)
        }
    }
}

extension View {
    /// Indents a line past the bars of `groups`, outermost first, and reports
    /// its frame to each of them.
    @ViewBuilder
    func agentGroupMember(_ groups: [Int]) -> some View {
        if groups.isEmpty {
            self
        } else {
            padding(.leading, CGFloat(groups.count) * AgentGroupBar.indent)
                .anchorPreference(key: AgentGroupBarFrames.self, value: .bounds) { anchor in
                    Dictionary(uniqueKeysWithValues: groups.enumerated().map { level, group in
                        (group, AgentGroupBarFrames.Group(level: level, lines: [anchor]))
                    })
                }
        }
    }

    /// Draws the bars of the groups reported inside this view, and keeps their
    /// frames from reaching any view above it.
    func agentGroupBars(isEnabled: Bool, style: AgentGroupBar.Style) -> some View {
        overlayPreferenceValue(AgentGroupBarFrames.self) { groups in
            if isEnabled, !groups.isEmpty {
                AgentGroupBar.bars(groups, style: style)
            }
        }
        .transformPreference(AgentGroupBarFrames.self) { $0 = [:] }
    }
}

extension AgentGroupBar {
    /// Each bar keeps its center while it widens, so it grows into the
    /// gutter on both sides and the text beside it never moves.
    fileprivate static func bars(_ groups: [Int: AgentGroupBarFrames.Group], style: Style) -> some View {
        GeometryReader { proxy in
            ForEach(groups.keys.sorted(), id: \.self) { key in
                if let group = groups[key], let frame = frame(of: group, in: proxy) {
                    let look = style.looks[key] ?? .normal
                    let color = style.colors[key] ?? style.color
                    let width = width(of: look, lineWidth: style.lineWidth)
                    let height = frame.height - 2 * endInset
                    if height > width {
                        Capsule()
                            .fill(color)
                            .animation(colorFade, value: color)
                            .frame(width: width, height: height)
                            .position(
                                x: frame.minX + CGFloat(group.level) * indent + style.lineWidth / 2,
                                y: frame.midY
                            )
                            .animation(animation(to: look), value: look)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func frame(of group: AgentGroupBarFrames.Group, in proxy: GeometryProxy) -> CGRect? {
        guard let first = group.lines.first else { return nil }
        return group.lines.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
    }
}

/// Reports a left-button press while the pointer is over an agent group.
/// It watches events rather than adding a gesture, so the row's tap,
/// double-click, drag and context menu see the mouse exactly as before.
/// Moving past `AgentGroupBar.pressSlop` ends the press, because that is
/// the row's drag starting.
@MainActor
final class AgentGroupPressMonitor {
    private var monitor: Any?
    private var downLocation: CGPoint?
    private var onChange: (Bool) -> Void = { _ in }

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endPress()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A control-click opens the context menu.
            guard !event.modifierFlags.contains(.control) else { return }
            downLocation = event.locationInWindow
            onChange(true)
        case .leftMouseDragged:
            guard let downLocation else { return }
            let location = event.locationInWindow
            if hypot(location.x - downLocation.x, location.y - downLocation.y) > AgentGroupBar.pressSlop {
                endPress()
            }
        default:
            endPress()
        }
    }

    private func endPress() {
        guard downLocation != nil else { return }
        downLocation = nil
        onChange(false)
    }
}
