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
    /// How far a hovered group's wash reaches past its lines.
    static let washOutset = CGSize(width: 4, height: 1)
    static let washCornerRadius: CGFloat = 6

    #if DEBUG
    /// Swaps the hover wash for darker text and a highlighted bar.
    static let debugHoverEmphasisKey = "PlumeDebugAgentGroupHoverEmphasis"
    #endif

    static func lineWidth(captionSize: CGFloat) -> CGFloat {
        InfoPaneBracketStub(pointSize: captionSize, centerX: 0).lineWidth
    }

    /// A wash behind one group, named by its header index.
    struct Wash {
        var group: Int
        var color: Color
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
    /// frames from reaching any view above it. A group in `highlights` draws
    /// its bar in that color instead of `color`.
    func agentGroupBars(
        isEnabled: Bool,
        color: Color,
        lineWidth: CGFloat,
        highlights: [Int: Color] = [:],
        wash: AgentGroupBar.Wash? = nil
    ) -> some View {
        backgroundPreferenceValue(AgentGroupBarFrames.self) { groups in
            if isEnabled, let wash, let group = groups[wash.group] {
                AgentGroupBar.wash(group, color: wash.color)
            }
        }
        .overlayPreferenceValue(AgentGroupBarFrames.self) { groups in
            if isEnabled, !groups.isEmpty {
                AgentGroupBar.bars(groups, color: color, highlights: highlights, lineWidth: lineWidth)
            }
        }
        .transformPreference(AgentGroupBarFrames.self) { $0 = [:] }
    }
}

extension AgentGroupBar {
    fileprivate static func bars(
        _ groups: [Int: AgentGroupBarFrames.Group],
        color: Color,
        highlights: [Int: Color],
        lineWidth: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            ZStack {
                Path { path in
                    for (key, group) in groups where highlights[key] == nil {
                        addBar(group, to: &path, in: proxy, lineWidth: lineWidth)
                    }
                }
                .stroke(color, style: style)
                ForEach(highlights.keys.sorted(), id: \.self) { key in
                    if let group = groups[key], let highlight = highlights[key] {
                        Path { addBar(group, to: &$0, in: proxy, lineWidth: lineWidth) }
                            .stroke(highlight, style: style)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func addBar(
        _ group: AgentGroupBarFrames.Group,
        to path: inout Path,
        in proxy: GeometryProxy,
        lineWidth: CGFloat
    ) {
        guard let frame = frame(of: group, in: proxy) else { return }
        let x = frame.minX + CGFloat(group.level) * indent + lineWidth / 2
        let inset = endInset + lineWidth / 2
        guard frame.maxY - inset > frame.minY + inset else { return }
        path.move(to: CGPoint(x: x, y: frame.minY + inset))
        path.addLine(to: CGPoint(x: x, y: frame.maxY - inset))
    }

    fileprivate static func wash(_ group: AgentGroupBarFrames.Group, color: Color) -> some View {
        GeometryReader { proxy in
            if let frame = frame(of: group, in: proxy) {
                let leading = frame.minX + CGFloat(group.level) * indent - washOutset.width
                let rect = CGRect(
                    x: leading,
                    y: frame.minY - washOutset.height,
                    width: frame.maxX + washOutset.width - leading,
                    height: frame.height + 2 * washOutset.height
                )
                RoundedRectangle(cornerRadius: washCornerRadius)
                    .fill(color)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private static func frame(of group: AgentGroupBarFrames.Group, in proxy: GeometryProxy) -> CGRect? {
        guard let first = group.lines.first else { return nil }
        return group.lines.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
    }
}
