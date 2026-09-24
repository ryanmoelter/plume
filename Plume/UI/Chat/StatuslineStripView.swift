import SwiftUI
import Foundation

/// The statusline strip's meters: context-window use, 5h/7d quota and session
/// cost — a native equivalent of `~/.scripts/.claude/statusline.sh`.
///
/// Context and cost are plain parameters, per session. Quota is not: it
/// belongs to the account, so it comes from `QuotaStore.shared` and reads the
/// same in every chat. `contextMaxTokens` may be a measured value or the
/// model's assumed window — the label makes no distinction, by design. Cost
/// only reaches a headless session, so that segment renders only when the
/// stream has pushed it.
///
/// Each meter stacks its reading over its bar. Side by side the two ran the
/// full width of the panel for what is a percentage; stacked, the bar can be
/// no wider than the number above it.
///
/// The strip hugs its content: `ChatTabView.statuslineFooter` puts the
/// workspace group on the row's leading edge and Remote Control on its
/// trailing one, so the whole row reads left to right as where this runs,
/// then what it has spent.
///
/// Which of the two layouts to draw is the caller's decision, not this
/// view's: `ChatTabView.statuslineFooter` runs one `ViewThatFits` over the
/// whole row, so the branch name and the meters give way in a single
/// ordering rather than shrinking against each other.
///
/// What a message will do next — permission mode, model, effort — lives in
/// `ChatComposer` instead: those describe the *next* turn, not the session as
/// a whole, and reading them at the point of sending is more useful than
/// reading them above the transcript. Both rows share the segment styling
/// `ComposerControlsRow.swift` defines (`ComposerSegmentLabel`,
/// `StatuslineColors`).
struct StatuslineStripView: View, ThemedView {
    @Environment(\.theme) var theme

    let layout: StatuslineStripLayout
    let provider: AgentProviderKind

    // Transcript-derived, so available on either transport.
    let contextUsedTokens: Int?
    let contextMaxTokens: Int?

    // Stream-derived, headless only — nil segments are simply omitted.
    let sessionCostUSD: Double?

    /// Account-wide, so it comes from the shared store rather than from the
    /// session this strip belongs to: a chat that has not taken a turn in an
    /// hour still shows what the account heard a moment ago.
    @State private var quota = QuotaStore.shared

    init(
        layout: StatuslineStripLayout = .wide,
        provider: AgentProviderKind = .claudeCode,
        contextUsedTokens: Int? = nil,
        contextMaxTokens: Int? = nil,
        sessionCostUSD: Double? = nil
    ) {
        self.layout = layout
        self.provider = provider
        self.contextUsedTokens = contextUsedTokens
        self.contextMaxTokens = contextMaxTokens
        self.sessionCostUSD = sessionCostUSD
    }

    var body: some View {
        Group {
            switch layout {
            case .wide: wideLayout
            case .stacked: stackedLayout
            }
        }
        .font(typography.caption.font)
        .onAppear { quota.startTicking() }
    }

    private var rateLimit: RateLimitInfo? { provider == .claudeCode ? quota.snapshot?.rateLimit : nil }

    private var isStale: Bool {
        guard let snapshot = quota.snapshot else { return false }
        return QuotaFreshness.isStale(receivedAt: snapshot.receivedAt, now: quota.now)
    }

    // MARK: - Layouts

    private var wideLayout: some View {
        // Top-aligned: a meter's reading is its first line, so the meters line
        // up along it whether or not a bar follows. The cost opts back out.
        HStack(alignment: .top, spacing: dimensions.statuslineSegmentSpacing) {
            contextSegment(showsReading: true)
            if let fiveHour = rateLimit?.fiveHour, fiveHour.utilization > 0 {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.shortQuota,
                    windowLength: QuotaWindowLength.fiveHour
                )
                .plumeID(AccessibilityID.statuslineFiveHourMeter)
            }
            if let sevenDay = rateLimit?.sevenDay, sevenDay.utilization > 0 {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.quota,
                    windowLength: QuotaWindowLength.sevenDay
                )
                .plumeID(AccessibilityID.statuslineSevenDayMeter)
            }
            if let sessionCostUSD {
                costSegment(sessionCostUSD)
                    .plumeID(AccessibilityID.statuslineCost)
            }
        }
        .fixedSize()
    }

    /// Bars only, stacked top to bottom instead of side by side, and no cost
    /// — what the row falls back to once `wideLayout` no longer fits.
    /// `statuslineStackedBarSpacing` keeps the three bars within the height
    /// one reading-over-bar meter already takes.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: dimensions.statuslineStackedBarSpacing) {
            contextSegment(showsReading: false)
            if let fiveHour = rateLimit?.fiveHour, fiveHour.utilization > 0 {
                StatuslineMeterSegment(
                    label: "5h",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.shortQuota,
                    showsReading: false,
                    windowLength: QuotaWindowLength.fiveHour
                )
                .plumeID(AccessibilityID.statuslineFiveHourMeter)
            }
            if let sevenDay = rateLimit?.sevenDay, sevenDay.utilization > 0 {
                StatuslineMeterSegment(
                    label: "7d",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: quota.now,
                    isStale: isStale,
                    barWidth: StatuslineMeterWidth.quota,
                    showsReading: false,
                    windowLength: QuotaWindowLength.sevenDay
                )
                .plumeID(AccessibilityID.statuslineSevenDayMeter)
            }
        }
    }

    // MARK: - Segments

    @ViewBuilder
    private func contextSegment(showsReading: Bool) -> some View {
        let percent = percentage(used: contextUsedTokens, max: contextMaxTokens)

        if contextUsedTokens != nil || percent != nil {
            let attention = StatuslineAttention.attention(contextTokens: contextUsedTokens, percent: percent)
            StackedMeter(
                reading: tokenLabel(used: contextUsedTokens, max: contextMaxTokens),
                fraction: StatuslineMeterMath.fraction(percent: percent),
                barWidth: StatuslineMeterWidth.context,
                attention: attention,
                showsReading: showsReading
            )
            .help("Context window used")
            .accessibilityLabel("Context window")
            .plumeID(AccessibilityID.statuslineContextMeter)
        }
    }

    /// Centred rather than top-aligned with the readings beside it: the cost
    /// is not a measurement of a limit, it is how much this would cost at API
    /// prices. Centring is what says that — sharing the meters' reading line
    /// would file it as one more quota.
    private func costSegment(_ cost: Double) -> some View {
        Text(String(format: "$%.2f", cost))
            .foregroundStyle(StatuslineColors.statuslineText(for: .neutral, colors: colors))
            .help("What this session has cost so far")
            .frame(maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func percentage(used: Int?, max: Int?) -> Double? {
        guard let used, let max, max > 0 else { return nil }
        return Double(used) / Double(max) * 100
    }

    private func tokenLabel(used: Int?, max: Int?) -> String {
        let usedText = used.map(formatTokenCount) ?? "0"
        let maxText = max.map(formatTokenCount) ?? "—"
        return "\(usedText)/\(maxText)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }
}

/// Which shape the strip draws. `ChatTabView.statuslineFooter` picks one per
/// `ViewThatFits` candidate: `wide` is the full row of side-by-side meters
/// with their readings and the session cost, `stacked` is the same meters as
/// bars alone, one above the next.
enum StatuslineStripLayout {
    case wide
    case stacked
}

/// Bar lengths: the context window and the seven-day quota read most
/// precisely, the five-hour quota less so. The row lays out from each
/// segment's own intrinsic size rather than squeezing to fit, so these can run
/// a bit longer than a reading needs and still cost nothing but the branch
/// chip's own truncation room. The stacked layout reuses the same widths, so a
/// bar means the same thing whichever layout is showing.
enum StatuslineMeterWidth {
    static let context: CGFloat = 50
    static let quota: CGFloat = 50
    static let shortQuota: CGFloat = 36

    /// The sidebar footer has width the statusline does not — it is not
    /// competing with a branch chip — so its quota bars run longer. Kept apart
    /// from the strip's own widths so the two can be tuned independently.
    static let sidebarQuota: CGFloat = 54
    static let sidebarShortQuota: CGFloat = 42
}

/// How long each quota window runs, for deriving how far through it the clock
/// is: the stream reports only when a window resets, never when it opened.
enum QuotaWindowLength {
    static let fiveHour: TimeInterval = 5 * 3600
    static let sevenDay: TimeInterval = 7 * 86400
}

/// A reading over its bar — the shape every meter in the strip takes.
struct StackedMeter: View, ThemedView {
    @Environment(\.theme) var theme

    let reading: String
    let fraction: Double
    let barWidth: CGFloat
    let attention: StatuslineAttention
    /// The stacked statusline layout drops the reading and keeps only the
    /// bar; the reading still reaches VoiceOver, as the bar's
    /// `accessibilityValue`, rather than disappearing with the label.
    var showsReading: Bool = true
    var pacing: Double?
    /// Leading rather than centered, for a row whose bars have to line up
    /// with content below them.
    var readingAlignment: HorizontalAlignment = .center
    /// Steps the fill and the reading back one emphasis level. Deliberately
    /// not an opacity over the whole meter: the track and the pacing mark are
    /// already faint by design, and dimming them too would fade the frame the
    /// reading is measured against rather than the reading itself.
    var isStale: Bool = false

    var body: some View {
        let bar = MeterView(
            fraction: fraction,
            color: StatuslineColors.meter(for: attention, colors: colors),
            attention: attention,
            pacing: pacing,
            isStale: isStale
        )
        .frame(width: barWidth)
        if showsReading {
            // Centered rather than leading: the reading and the bar rarely
            // share a width (a short reading over a long bar, or the
            // reverse), and centering is what keeps whichever is narrower
            // looking placed rather than merely left-aligned with the other.
            VStack(alignment: readingAlignment, spacing: dimensions.statuslineMeterSpacing) {
                Text(reading)
                    .foregroundStyle(StatuslineColors.statuslineText(for: attention, colors: colors))
                    .opacity(isStale ? colors.emphasis[.secondary] : 1)
                    .lineLimit(1)
                bar
            }
        } else {
            bar.accessibilityValue(reading)
        }
    }
}

/// A quota window's compact meter: the reset countdown and the percentage —
/// `5d 15%` — over its bar.
struct StatuslineMeterSegment: View, ThemedView {
    @Environment(\.theme) var theme
    @State private var showingDetails = false

    let label: String
    /// 0–1, matching the stream's own `utilization` — scaled to a percent
    /// once, here, rather than by each caller.
    let utilization: Double
    let resetsAt: Date?
    /// Supplied by `QuotaStore`'s tick rather than read as `Date()`, so the
    /// countdown re-renders every minute instead of at whatever else happens
    /// to invalidate the view.
    var now: Date = Date()
    /// Dims the whole meter once the reading is old enough that presenting it
    /// at full strength would overstate what is known.
    var isStale: Bool = false
    /// Bar length carries how finely the number is worth reading. Context
    /// deserves the most precision, then the seven-day window; the five-hour
    /// quota moves fast enough that its exact percent matters least.
    var barWidth: CGFloat = StatuslineMeterWidth.quota
    var showsReading: Bool = true
    /// The window's own length, which turns `resetsAt` into how far through
    /// it the clock is. Nil draws no pacing band.
    var windowLength: TimeInterval?
    var readingAlignment: HorizontalAlignment = .center

    var body: some View {
        let percent = utilization * 100
        Button {
            showingDetails = true
        } label: {
            StackedMeter(
                reading: "\(resetLabel) \(Int(percent.rounded()))%",
                fraction: StatuslineMeterMath.fraction(percent: percent),
                barWidth: barWidth,
                attention: StatuslineAttention.attention(percent: percent),
                showsReading: showsReading,
                pacing: windowLength.flatMap {
                    QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: $0)
                },
                readingAlignment: readingAlignment,
                isStale: isStale
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityLabel("\(label) quota")
        .accessibilityValue("\(Int(percent.rounded()))% used, \(resetDescription)")
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(label) quota")
                    .font(.headline)
                Text("Used: \(Int(percent.rounded()))%")
                Text("Resets: \(resetDescription)")
            }
            .font(typography.caption.font)
            .padding(12)
            .frame(minWidth: 160, alignment: .leading)
            .environment(\.theme, theme)
        }
    }

    /// Two lines: what has been spent against how much of the window has
    /// gone, then when it refills. The elapsed share is what the pacing mark
    /// draws, said in words — the mark shows the comparison but not the
    /// number behind it.
    private var helpText: String {
        var first = "\(Int((utilization * 100).rounded()))% of \(label) quota used"
        if let windowLength,
           let elapsed = QuotaFreshness.pacing(resetsAt: resetsAt, now: now, window: windowLength) {
            first += ", \(Int((elapsed * 100).rounded()))% of time elapsed"
        }
        if isStale { first += " (last heard over 30 minutes ago)" }
        guard let resetsAt else { return first }
        let reset = QuotaFreshness.absoluteResetLabel(resetsAt: resetsAt, now: now)
        return "\(first)\nResetting at \(reset)"
    }

    private var resetLabel: String {
        QuotaFreshness.resetLabel(resetsAt: resetsAt, now: now, fallback: label)
    }

    private var resetDescription: String {
        guard let resetsAt else { return "Unavailable" }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        return "in \(resetLabel)"
    }
}

/// Remote Control's own segment, driving the same `setRemoteControl` the
/// typed `/rc` does. A session-wide fact like quota and cost, so it sits in
/// the statusline rather than beside the next turn's settings. Absent before
/// a session exists, since there is no bridge to attach to until then.
struct RemoteControlControl: View, ThemedView {
    @Environment(\.theme) var theme
    let session: any AgentSession
    @State private var showsCodexDetails = false

    private enum State {
        case off, connecting, on, failed(String)
    }

    private var codexRemote: CodexRemoteControl? {
        (session as? CodexSession)?.effectiveRemoteControl
    }

    private var state: State {
        if let remote = codexRemote {
            // Pairing/device-management failures do not turn off a live host.
            if remote.status == .connected { return .on }
            if remote.status == .connecting || remote.operation == .enabling { return .connecting }
            if let error = remote.operationError { return .failed(error) }
            switch remote.status {
            case .disabled: return .off
            case .connecting: return .connecting
            case .connected: return .on
            case .errored: return .failed("Codex could not establish remote access")
            }
        }
        guard let claude = session as? HeadlessSession else { return .off }
        switch claude.remoteControl {
        case .disconnected: return .off
        case .connecting: return .connecting
        case .connected: return .on
        case .failed(let error): return .failed(error)
        }
    }

    private var isEnabled: Bool {
        if let remote = codexRemote { return remote.isAvailableForRemoteAccess }
        switch state {
        case .on, .connecting: return true
        case .off, .failed: return false
        }
    }

    var body: some View {
        Menu {
            Button(isEnabled ? "Disconnect Remote Control" : "Connect Remote Control") {
                let enabled = !isEnabled
                if let remote = codexRemote {
                    if enabled { showsCodexDetails = true }
                    Task { await remote.setEnabled(enabled) }
                } else if let claude = session as? HeadlessSession {
                    claude.setRemoteControl(enabled: enabled)
                }
            }
            .disabled(codexRemote?.operation == .disabling)
            if codexRemote != nil {
                Button("Pair and Manage Devices…") { showsCodexDetails = true }
            } else if let claude = session as? HeadlessSession,
                      case .connected(let link) = claude.remoteControl,
                      let url = link.shareableURL {
                Button("Copy Remote Control Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        } label: {
            ComposerSegmentLabel(systemImage: symbol, text: "Remote Control", showsText: false, foreground: tint)
        }
        .menuStyle(.borderlessButton)
        .font(typography.caption.font)
        .fixedSize()
        .frame(maxHeight: .infinity)
        .help(helpText)
        .accessibilityLabel("Remote Control")
        .accessibilityValue(accessibilityValue)
        .plumeID(AccessibilityID.composerRemoteControlControl, value: accessibilityValue,
                 invoke: codexRemote == nil ? nil : { showsCodexDetails = true })
        .sheet(isPresented: $showsCodexDetails) {
            if let remote = codexRemote { CodexRemoteControlPanel(remote: remote) }
        }
    }

    private var symbol: String {
        switch state {
        case .on, .connecting: return StatusSymbol.remoteControl.name
        case .off, .failed: return "\(StatusSymbol.remoteControl.name).slash"
        }
    }

    private var tint: Color {
        switch state {
        case .on: return colors.attention
        case .failed: return colors.danger
        case .connecting, .off: return colors.foreground.opacity(colors.emphasis[.secondary])
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .off: return "Off"
        case .connecting: return "Connecting"
        case .on: return "On"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var helpText: String {
        switch state {
        case .on:
            return codexRemote != nil
                ? "Remote Control is on — manage this Codex host and paired devices"
                : "Remote Control is on — this session is on claude.ai/code"
        case .connecting: return "Connecting to Remote Control…"
        case .failed(let message): return "Remote Control failed: \(message)"
        case .off:
            return codexRemote != nil
                ? "Remote Control — pair a device with this Codex host"
                : "Remote Control — drive this session from your phone or claude.ai/code"
        }
    }
}

/// Pure percent-to-fraction arithmetic shared by every meter, kept apart from
/// any view so it can be tested without SwiftUI.
enum StatuslineMeterMath {
    /// Clamps a percent (0–100, or nil) to the 0–1 fraction `MeterView` fills.
    static func fraction(percent: Double?) -> Double {
        guard let percent else { return 0 }
        return Swift.min(Swift.max(percent / 100, 0), 1)
    }

    /// The fill's width in points, clamped to the track's own width so a
    /// fraction at or past 1 can never draw the fill past the track —
    /// `MeterView` clips to the track's shape too, as a second line of
    /// defense against rendering quirks at narrow track widths.
    static func fillWidth(trackWidth: CGFloat, fraction: Double) -> CGFloat {
        guard trackWidth > 0 else { return 0 }
        let width = trackWidth * fraction
        return Swift.min(Swift.max(width, 0), trackWidth)
    }
}

/// Attention-to-color mapping shared by the strip and the composer's
/// controls row, so a segment moved between them keeps its meaning.
enum StatuslineColors {
    /// The meter's own fill, which is a graphic rather than text — so a
    /// neutral meter dims the theme foreground instead of borrowing the text
    /// hierarchy, which a `Capsule` fill cannot use.
    static func meter(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground.opacity(colors.emphasis[.secondary])
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }

    static func foreground(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground
        case .yellow: return colors.warning
        case .red: return colors.danger
        }
    }

    /// The strip's own text: neutral dims to secondary so the eye lands on
    /// the box content and the composer's model/effort/permission dropdowns
    /// instead, while yellow and red keep `foreground`'s full-strength
    /// attention hue — that is the one signal this row still needs to win.
    /// `ComposerControlsRow` keeps calling `foreground` directly, since its
    /// dropdowns are next-turn controls the row is not trying to de-emphasize.
    static func statuslineText(for attention: StatuslineAttention, colors: Palette) -> Color {
        switch attention {
        case .neutral: return colors.foreground.opacity(colors.emphasis[.secondary])
        case .yellow, .red: return foreground(for: attention, colors: colors)
        }
    }
}

/// A small capsule meter — the native stand-in for the shell script's braille
/// bars, not a reproduction of them.
struct MeterView: View, ThemedView {
    @Environment(\.theme) var theme

    let fraction: Double
    let color: Color
    /// Drives the pacing dot's own tint via `StatuslineColors.foreground`,
    /// kept apart from `color` because that one carries a baked-in opacity
    /// for the neutral case that the dot's own emphasis levels already
    /// apply.
    let attention: StatuslineAttention
    /// How far through the window the clock is, 0–1. Drawn as a dot on the
    /// bar, so the fill's position against it reads the same whether the fill
    /// is short of it or past it. Nil draws nothing, which is what every
    /// non-quota meter wants — a context window does not refill on a clock.
    var pacing: Double?
    /// Dims the fill alone. The track stays put — see `StackedMeter.isStale`.
    var isStale: Bool = false

    private var trackOpacity: Double {
        colors.emphasis[.divider]
    }

    var body: some View {
        GeometryReader { geometry in
            let fillWidth = StatuslineMeterMath.fillWidth(trackWidth: geometry.size.width, fraction: fraction)
            let mark = pacing.map {
                PacingMark.offset(pacing: $0, barWidth: geometry.size.width)
            }

            // Centred vertically as well as leading, so the dot sits on the
            // bar's midline rather than its top edge. Clipped to the track's
            // own shape: at narrow track widths a capsule's rounded caps can
            // otherwise render past the nominal frame, spilling the fill past
            // the track it sits over.
            ZStack(alignment: Alignment(horizontal: .leading, vertical: .center)) {
                Capsule()
                    .fill(color.opacity(trackOpacity))

                // The dot is drawn twice at the one position: once here, over
                // the track, and once clipped to the fill. Each copy carries
                // the contrast its own ground needs, so a dot straddling the
                // fill's edge reads whole instead of changing shape there —
                // which is exactly where the comparison matters most.
                if let mark {
                    dot(at: mark, isOverFill: false)
                }

                Capsule()
                    .fill(color)
                    .opacity(isStale ? colors.emphasis[.secondary] : 1)
                    .frame(width: fillWidth)

                if let mark {
                    dot(at: mark, isOverFill: true)
                        .frame(width: fillWidth, alignment: .leading)
                        .clipped()
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: PacingMark.barHeight)
    }

    /// One copy of the dot, colored for the ground it lands on. Over the
    /// fill it is a hole punched in the bar; over the bare track, which is
    /// itself a wash on that same ground, a hole would vanish, so it draws
    /// as content instead, in the same warning/danger tint the fill wears
    /// once utilization crosses into those bands. Both sit at secondary
    /// emphasis, which is what keeps the mark from outweighing the fill it
    /// annotates.
    private func dot(at offset: CGFloat, isOverFill: Bool) -> some View {
        let ground = isOverFill
            ? colors.background ?? Color(nsColor: .windowBackgroundColor)
            : StatuslineColors.foreground(for: attention, colors: colors)
        return Circle()
            .fill(ground.opacity(colors.emphasis[isOverFill ? .secondary : .subtle]))
            .frame(width: PacingMark.width, height: PacingMark.width)
            .offset(x: offset)
    }
}

/// The pacing mark's look, shared so the sidebar and the statusline draw the
/// same thing at different bar lengths.
enum PacingMark {
    /// The meter's own height, which the dot is sized against.
    static let barHeight: CGFloat = 5

    /// A dot rather than a full-height line, so the track shows above and
    /// below it. That margin is what keeps the mark reading as a position
    /// once the pacing nears the end of the bar, where a full-height mark
    /// merges into the bar's own rounded cap.
    ///
    /// Sized to leave a ring of track either side; a dot as tall as the bar
    /// would read as a fat line with rounded ends instead.
    static let width: CGFloat = 3.5

    /// The leading edge of a dot whose *center* sits at the pacing fraction,
    /// which is the position being compared against the fill's own edge.
    ///
    /// The travel is not inset by the dot's width: insetting would buy a
    /// whole dot at either end at the cost of reading early everywhere in
    /// between. The ends clip instead.
    static func offset(pacing: Double, barWidth: CGFloat) -> CGFloat {
        barWidth * pacing - width / 2
    }
}

#Preview("Terminal transport") {
    StatuslineStripView(
        contextUsedTokens: 82_000,
        contextMaxTokens: 200_000
    )
    .frame(width: 640)
}

#Preview("Headless transport") {
    StatuslineStripView(
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        sessionCostUSD: 4.32
    )
    .frame(width: 640)
}

#Preview("Stacked fallback") {
    StatuslineStripView(
        layout: .stacked,
        contextUsedTokens: 620_000,
        contextMaxTokens: 1_000_000,
        sessionCostUSD: 4.32
    )
    .frame(width: 100)
}
