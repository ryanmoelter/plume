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

    static func lineWidth(captionSize: CGFloat) -> CGFloat {
        InfoPaneBracketStub(pointSize: captionSize, centerX: 0).lineWidth
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
    func agentGroupMember(_ groups: [Int]) -> some View {
        padding(.leading, CGFloat(groups.count) * AgentGroupBar.indent)
            .anchorPreference(key: AgentGroupBarFrames.self, value: .bounds) { anchor in
                Dictionary(uniqueKeysWithValues: groups.enumerated().map { level, group in
                    (group, AgentGroupBarFrames.Group(level: level, lines: [anchor]))
                })
            }
    }

    func agentGroupBars(color: Color, lineWidth: CGFloat) -> some View {
        overlayPreferenceValue(AgentGroupBarFrames.self) { groups in
            GeometryReader { proxy in
                Path { path in
                    for group in groups.values {
                        guard let first = group.lines.first else { continue }
                        let frame = group.lines.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                        let x = frame.minX + CGFloat(group.level) * AgentGroupBar.indent + lineWidth / 2
                        let inset = AgentGroupBar.endInset + lineWidth / 2
                        guard frame.maxY - inset > frame.minY + inset else { continue }
                        path.move(to: CGPoint(x: x, y: frame.minY + inset))
                        path.addLine(to: CGPoint(x: x, y: frame.maxY - inset))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .allowsHitTesting(false)
        }
    }
}
