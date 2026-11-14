import SwiftUI
import Combine   // Timer.publish, for the ticking elapsed time on local jobs

struct PopoverView: View {
    @EnvironmentObject var viewModel: UsageViewModel

    // How tall the usage would be laid out in full, measured inside the scroll
    // view so the popover can be exactly that tall until it runs out of screen.
    @State private var usageHeight: CGFloat = 0

    // The account whose card is open under the rings, by provider id. None is
    // open at each launch.
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // No title row. You know which app you just clicked, and in a
            // popover this tall the app's own name is the least useful line in
            // it — more so once several accounts each carry their own heading.
            // Refresh moved to the footer, next to the freshness it acts on.

            // The divider belongs to the banner, not to the top of the window —
            // without the old title row above it, an unconditional one drew a
            // stray line against the popover's own edge.
            if !viewModel.claudeStatus.isHealthy {
                StatusBannerView(status: viewModel.claudeStatus)
                Divider()
            }

            // Several accounts' worth of bars, forecasts and history is taller
            // than a laptop screen, and a popover that runs off the screen is
            // simply cut off. The usage scrolls once it would; the footer stays.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    content

                    if !dayLanes.isEmpty {
                        DayStripView(lanes: dayLanes,
                                     windowLength: UsageForecaster.windowLength(forKey: "session"))
                            .card(nil)
                    }
                }
                .padding(12)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: UsageHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(usageHeight, maxUsageHeight))
            .onPreferenceChange(UsageHeightKey.self) { usageHeight = $0 }

            // Only appears while something is actually running — an idle section
            // would just be clutter in a popover you open to check a number.
            if viewModel.isLocalBusy {
                Divider()
                LocalJobsSection(jobs: viewModel.localJobs,
                                 completed: viewModel.localCompleted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            Divider()

            // Footer
            HStack(spacing: 4) {
                if viewModel.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(footerText)
                    .font(.caption2)
                    .foregroundStyle(viewModel.isStale ? Color.orange : Color.subtleText)
                // Refresh sits with "Updated 2 min ago" because that is the
                // thing it changes.
                if viewModel.isLoading {
                    ProgressView().scaleEffect(0.5)
                } else {
                    Button { viewModel.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.subtleText)
                    .help("Refresh now")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.subtleText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        // Near-opaque charcoal under everything. The popover's own material
        // is a blur of the desktop, which is where the text got hard to
        // read; a trace of it still shows so the panel sits on the screen
        // rather than on top of it.
        .background(Color.panel.ignoresSafeArea())
    }

    // What the screen leaves for the scrolling part: the menu bar, the
    // popover's arrow, the footer, and the status banner and local-model
    // section that sit outside it.
    private var maxUsageHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 180
    }

    // One lane of today's session windows per signed-in account, for the
    // strip. A lane is only worth showing once there's more than the window
    // you're currently in — one block on its own explains nothing. Lanes are
    // named once there's more than one account to tell apart.
    private var dayLanes: [DayStripView.Lane] {
        let length = UsageForecaster.windowLength(forKey: "session")
        // The strip's axis is today, so fetch anything overlapping today.
        let start = Calendar.current.startOfDay(for: Date())
        var seen = Set<String>()
        let accounts = viewModel.workspaces.filter { seen.insert($0.providerID).inserted }
        let signedIn = Set(viewModel.signedInWorkspaces.map(\.providerID))
        return accounts.filter { signedIn.contains($0.providerID) }.compactMap { ws in
            let windows = UsageHistory.shared.windows(providerID: ws.providerID, metricKey: "session",
                                                      from: start,
                                                      to: start.addingTimeInterval(24 * 3600),
                                                      windowLength: length)
            guard windows.count >= 2 else { return nil }
            return DayStripView.Lane(id: ws.providerID,
                                     name: accounts.count > 1 ? ws.providerName : nil,
                                     swatch: viewModel.account(forProvider: ws.providerID)?.swatch,
                                     windows: windows)
        }
    }

    private var footerText: String {
        if viewModel.isWaitingForNetwork {
            return viewModel.lastUpdated == nil ? "Waiting for the network"
                : "Waiting for the network — updated \(viewModel.lastUpdatedText)"
        }
        if viewModel.lastUpdated == nil { return "Not yet loaded" }
        if viewModel.isStale { return "Stale — updated \(viewModel.lastUpdatedText)" }
        return "Updated \(viewModel.lastUpdatedText)"
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.allSignedOut {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Sign in to see your usage")
                    .font(.callout).foregroundStyle(Color.subtleText)
                Button("Sign In") {
                    NotificationCenter.default.post(name: .openLogin, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

        } else {
            VStack(alignment: .leading, spacing: 10) {
                usage
            }
        }
    }

    // Every account as a ring tile: the Claude accounts in the order
    // Preferences lists them, signed in or not, then any other service that
    // has reported (Codex), the order kyl's usage file uses too. An account
    // waiting on a sign-in keeps its last rings, dimmed, with the way back in.
    private var tiles: [RingTile.Model] {
        let pending = Set(viewModel.pendingLogins.map(\.id))
        let claude = AccountStore.shared.accounts.map { account -> RingTile.Model in
            let id = ClaudeProvider.id(for: account)
            return RingTile.Model(id: id, name: account.name, swatch: account.swatch,
                                  rings: WorkspaceUsage.rings(of: viewModel.workspaces.filter { $0.providerID == id }),
                                  signedOut: pending.contains(account.id) ? account : nil)
        }
        let claudeIDs = Set(claude.map(\.id))
        var seen = Set<String>()
        let others = viewModel.workspaces
            .filter { !claudeIDs.contains($0.providerID) && seen.insert($0.providerID).inserted }
            .map { ws in
                RingTile.Model(id: ws.providerID, name: ws.providerName, swatch: nil,
                               rings: WorkspaceUsage.rings(of: viewModel.workspaces.filter { $0.providerID == ws.providerID }),
                               signedOut: nil)
            }
        return claude + others
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) { selected = selected == id ? nil : id }
    }

    @ViewBuilder
    private var usage: some View {
        let shown = viewModel.signedInWorkspaces
        let waiting = !viewModel.pendingLogins.isEmpty
        if shown.isEmpty, !waiting, let err = viewModel.errorMessage {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Couldn't load usage").font(.callout).foregroundStyle(Color.subtleText)
                Text(err).font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)

        } else if shown.isEmpty, !waiting {
            infoState(icon: "hourglass", text: "Loading your usage…")

        } else {
            let all = tiles
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, min(all.count, 2))),
                      spacing: 10) {
                ForEach(all) { tile in
                    RingTile(model: tile, selected: selected == tile.id) { toggle(tile.id) }
                }
            }
            // The open account's card, with pace, resets and history under
            // every bar. Headed against every account, signed in or not, so
            // its title doesn't change as another account's session comes and
            // goes.
            if let selected {
                ForEach(shown.filter { $0.providerID == selected }) { ws in
                    WorkspaceSection(workspace: ws,
                                     heading: ws.heading(among: viewModel.workspaces),
                                     swatch: viewModel.account(forProvider: ws.providerID)?.swatch,
                                     onClose: { toggle(selected) })
                }
            }
        }
    }

    private func infoState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(Color.subtleText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

private struct UsageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Rings

// One account as three concentric rings in its own colour, as the iPhone's
// Limits view draws them: the session outermost, then the week, then one
// model's own cap (WorkspaceUsage.rings), so a ring means the same thing on
// every account and needs no label. The fullest number sits in the middle and
// the name under the rings. A click opens the account's card below them, with
// pace, resets and history; an account waiting on a sign-in shows its last
// rings dimmed, with the way back in.
struct RingTile: View {
    struct Model: Identifiable {
        let id: String              // the provider id
        let name: String
        let swatch: Color?
        let rings: [UsageMetric?]   // the session, the week, a model's cap
        let signedOut: Account?     // set while the account waits on a sign-in
    }

    let model: Model
    let selected: Bool
    let onSelect: () -> Void

    // The fullest number, among limits that haven't reset since they were
    // read; "…" while every limit has, until the next check answers.
    private var middleText: String? {
        let present = model.rings.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        let current = present.filter { !$0.hasReset(at: Date()) }
        guard let fullest = current.max(by: { $0.percent < $1.percent }) else { return "…" }
        return "\(fullest.percent)%"
    }

    var body: some View {
        let colour = model.swatch ?? .primary
        VStack(spacing: 6) {
            ConcentricRings(rings: model.rings, colour: colour)
                .frame(width: 100, height: 100)
                .overlay {
                    if let middle = middleText {
                        Text(middle)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .opacity(model.signedOut == nil ? 1 : 0.35)
            Text(model.name).font(.caption).fontWeight(.semibold).lineLimit(1)
            if let account = model.signedOut {
                Button("Sign In") { (NSApp.delegate as? AppDelegate)?.showLoginWindow(for: account) }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? colour.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(selected ? "Click to close" : "Click for pace, resets and history")
    }
}

// Three rings, outermost first, each a faint track with an arc that fills
// clockwise from the top. An empty slot draws nothing, so the others keep
// their places, and each ring inward is a little fainter so the three stay
// apart in one colour. A limit getting close glows softly and one over pace
// glows strongly, so the ring keeps the account's colour while saying how
// close it is. A notch cut across each ring marks how much of its window has
// passed, so an arc running past its notch is quota spent faster than time.
// A limit that has reset since it was read is drawn faintly, with no notch,
// until the next check.
struct ConcentricRings: View {
    let rings: [UsageMetric?]
    let colour: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private let width: CGFloat = 8
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let now = Date()
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.offset) { index, metric in
                    if let metric {
                        ring(metric, at: CGFloat(index), now: now)
                        if !metric.hasReset(at: now), let elapsed = metric.elapsedFraction(at: now) {
                            notch(at: elapsed, index: CGFloat(index), side: min(geometry.size.width,
                                                                                  geometry.size.height))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The notches cut through the rings drawn beneath them, and
            // nothing else.
            .compositingGroup()
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rings.compactMap { $0 }.map { "\($0.label) \($0.percent) percent" }.joined(separator: ", "))
    }

    private func notch(at elapsed: Double, index: CGFloat, side: CGFloat) -> some View {
        let radius = side / 2 - index * (width + gap) - width / 2
        return Rectangle()
            .frame(width: 2, height: width + 2)
            .offset(y: -radius)
            .rotationEffect(.degrees(360 * elapsed))
            .blendMode(.destinationOut)
    }

    private func ring(_ metric: UsageMetric, at index: CGFloat, now: Date) -> some View {
        let inset = index * (width + gap) + width / 2
        let fill = shown ? CGFloat(min(max(metric.percent, 0), 100)) / 100 : 0
        let stale = metric.hasReset(at: now)
        let glow: Double = switch stale ? .ok : severity(percent: metric.percent, forecast: metric.forecast) {
        case .ok: 0
        case .warn: 0.45
        case .danger: 0.9
        }
        return ZStack {
            Circle().inset(by: inset).stroke(colour.opacity(0.16), lineWidth: width)
            if glow > 0, fill > 0 {
                // Kept tight, so an inner ring's glow doesn't cloud the
                // number in the middle.
                Circle().inset(by: inset).trim(from: 0, to: fill)
                    .stroke(colour, style: StrokeStyle(lineWidth: width + 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 4)
                    .opacity(glow)
            }
            Circle().inset(by: inset).trim(from: 0, to: fill)
                .stroke(colour.opacity((1 - 0.19 * Double(index)) * (stale ? 0.3 : 1)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: metric.percent)
    }
}

// MARK: - Cards

// The rounded tile each account, and today's sessions, sits on. An account's
// color tints it faintly, so a card reads as that account before its name
// does. The bars keep their own colors: those say on pace, getting close or
// over, and an account colored red would otherwise look permanently in
// trouble.
private struct Card: ViewModifier {
    let swatch: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(swatch?.opacity(0.11) ?? Color.primary.opacity(0.06)))
            .overlay(shape.strokeBorder(swatch?.opacity(0.3) ?? Color.primary.opacity(0.1),
                                        lineWidth: 0.5))
    }
}

extension View {
    fileprivate func card(_ swatch: Color?) -> some View { modifier(Card(swatch: swatch)) }
}

// An account's name, led by a dot of its color when it has one.
struct AccountLabel: View {
    let text: String
    let swatch: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                Circle().fill(swatch).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.subheadline).fontWeight(.semibold)
                .lineLimit(1)
        }
    }
}

// MARK: - One workspace's card

// What the rings leave out, for the account clicked: pace, reset and history
// under every bar. Clicking the card, or its rings again, closes it.
struct WorkspaceSection: View {
    let workspace: WorkspaceUsage
    // From WorkspaceUsage.heading(among:); nil when there's nothing to tell
    // apart, and the card then carries the account's own name.
    let heading: String?
    let swatch: Color?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                AccountLabel(text: heading ?? workspace.providerName, swatch: swatch)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if let session = workspace.session {
                UsageRowView(metric: session, resetStyle: .countdown,
                             providerID: workspace.providerID)
            }
            if let weekly = workspace.weeklyAll {
                UsageRowView(metric: weekly, resetStyle: .date,
                             providerID: workspace.providerID)
            }
            // Per-model weekly caps — Fable and friends appear here automatically.
            ForEach(workspace.weeklyModels) { model in
                UsageRowView(metric: model, resetStyle: .date,
                             providerID: workspace.providerID)
            }

            if workspace.extraEnabled {
                ExtraUsageRow(used: workspace.extraUsedCredits,
                              limit: workspace.extraMonthlyLimit,
                              currency: workspace.extraCurrency)
            }

            if let error = workspace.error {
                Text("⚠ \(error)")
                    .font(.caption2).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(swatch)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .help("Click to close")
    }
}

// A bar that fills to a percentage: a capsule on a faint track, never thinner
// than a dot so an empty limit still reads as a bar.
struct UsageBar: View {
    let percent: Int
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * CGFloat(min(percent, 100)) / 100))
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: height)
    }
}

extension UsageMetric {
    // On pace, getting close, over: the bar's and the percentage's color.
    var severityColor: Color {
        switch severity(percent: percent, forecast: forecast) {
        case .ok:     return .accentColor
        case .warn:   return .orange
        case .danger: return .red
        }
    }
}

// MARK: - One usage bar

struct UsageRowView: View {
    enum ResetStyle { case countdown, date }

    let metric: UsageMetric
    let resetStyle: ResetStyle
    var providerID: String = "claude"
    @ObservedObject private var prefs = Preferences.shared

    // Peaks of recent completed windows. Empty until a couple of windows have
    // closed, and the row simply omits the line until then.
    private var history: [Int] {
        UsageHistory.shared.series(providerID: providerID, metricKey: metric.key, limit: 12)
    }

    private var barColor: Color { metric.severityColor }

    // The pace forecast, when it has something to say. Shown *in addition to*
    // the reset line — never instead of it.
    private var forecastLine: String? {
        switch metric.forecast {
        case .atLimit:
            return "At limit"
        case .willHit(_, let runsOut):
            // The question people actually have is "how long do I have?", not
            // "how far ahead of the reset will I run dry?". Phrasing it against
            // the reset made the reset sound like the deadline, when the tokens
            // run out first.
            //
            // Clock time leads because that's what you plan against; the
            // duration follows for anyone who reads it the other way.
            guard prefs.showEndTimes else {
                return "About \(DateUtils.duration(runsOut)) left at this pace"
            }
            let at = DateUtils.clockTime(Date().addingTimeInterval(runsOut))
            return "At this pace you'll run out around \(at)"
        case .safe(let projected, let spare, _):
            // Report where you're heading, not how much slack is left.
            //
            // This used to show "~Nh to spare" and hide itself whenever that
            // figure exceeded the time remaining — a guard against the OLD
            // sample-based forecaster, which could claim "44h to spare" on a
            // 5-hour session. The forecaster is stateless average pace now and
            // can't produce that, so the guard only suppressed good output: past
            // the midpoint of a window it blanked the line entirely unless usage
            // was already high, which is exactly when you want the reassurance.
            //
            // Projected percentage is also just more useful — "about 45% by
            // reset" says where you land; hours-of-slack doesn't.
            // Answer the same question the willHit branch answers — "how long do
            // I have?" — rather than switching to a projected percentage.
            //
            // Reporting only "~67% by reset" meant the runway answer appeared
            // just when you were in trouble, so a light user never saw it and
            // reasonably concluded the feature wasn't there. When you're not
            // going to run out, the honest runway answer is "the reset is your
            // deadline, not your budget", which is what this says. The time
            // itself is deliberately left to the reset line right below, so the
            // two lines don't print the same clock time twice.
            _ = spare
            return "At this pace you're good through the reset (~\(projected)% used)"
        case .warmingUp:
            // Pace looks steep but too little used to trust — tell the user we're
            // watching without crying wolf.
            return "Calculating pace…"
        case .unknown:
            return nil
        }
    }

    // Time left / reset time — always shown when we know it.
    private var resetLine: String? {
        guard let reset = metric.resetAt else { return nil }
        // The number above was read before this reset, so it no longer holds.
        if metric.hasReset(at: Date()) {
            return "Reset at \(DateUtils.clockTime(reset)) · checking…"
        }
        switch resetStyle {
        case .countdown:
            // A session window is a rolling five hours anchored to whenever it
            // opened, not a fixed clock — so when it opened is half the story,
            // and it's the half nobody can see. Start work an hour before a
            // window closes and you get an hour of it, not five.
            let opened = reset.addingTimeInterval(-metric.window)
            if prefs.showEndTimes {
                return "Opened \(DateUtils.clockTime(opened)) · resets \(DateUtils.clockTime(reset))"
            }
            let ago = DateUtils.duration(-opened.timeIntervalSinceNow)
            return "Opened \(ago) ago · resets in \(DateUtils.mediumCountdown(to: reset))"
        case .date:      return "Resets \(DateUtils.resetDate(reset))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.cardLabel == metric.shortLabel ? metric.label : metric.cardLabel)
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(metric.hasReset(at: Date()) ? "…" : "\(metric.percent)%")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(barColor)
                    .monospacedDigit()
            }

            UsageBar(percent: metric.percent, color: barColor, height: 6)
                .opacity(metric.hasReset(at: Date()) ? 0.3 : 1)

            // Both lines wrap rather than truncate. Without fixedSize SwiftUI
            // compresses them to one line inside the fixed-width popover, and
            // the forecast — the longest string in the app — loses its tail:
            // "…good through the reset (~16% us…". A clipped sentence reads as
            // a broken app, and the number it eats is the point of the line.
            if let forecastLine {
                Text(forecastLine)
                    .font(.caption2)
                    .foregroundStyle(metric.forecast.isAlerting ? barColor : Color.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resetLine {
                Text(resetLine)
                    .font(.caption2)
                    .foregroundStyle(Color.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Recent history. Needs two closed windows before it says anything,
            // so it appears on its own once there's something to show.
            let past = history
            if past.count >= 2 {
                HStack(spacing: 6) {
                    // Deliberately NOT barColor. That's the metric's *live*
                    // severity, so a session forecast to run out repainted every
                    // past window red — including windows that finished at 20%.
                    // History is a record of what happened, not a reflection of
                    // what's happening now, and red has to mean exactly one
                    // thing: this window hit the cap.
                    UsageHistoryChart(values: past, color: .accentColor)
                        .frame(height: 18)
                    Text(historyCaption(past))
                        .font(.caption2)
                        .foregroundStyle(Color.subtleText)
                        .fixedSize()
                }
                .padding(.top, 1)
            }
        }
    }

    // "last 8 · maxed 3x" / "last 8 · peak 62%". The count of times you ran out
    // is the number that decides whether a plan fits; when it never happened,
    // the highest you reached is the useful stand-in.
    private func historyCaption(_ past: [Int]) -> String {
        let maxed = past.filter { $0 >= 100 }.count
        // Running out is the headline when it happens. When it doesn't, the
        // useful number is the opposite one: how much of what you pay for
        // expires unused. The chart already shows the peak.
        if maxed > 0 { return "last \(past.count) · maxed \(maxed)×" }
        let used = Double(past.reduce(0, +)) / Double(past.count)
        return "last \(past.count) · ~\(Int((100 - used).rounded()))% unused"
    }
}

// MARK: - Local models at work

// One row per local model currently generating. The elapsed time has to tick on
// its own — nothing else in the popover changes between the 3-minute fetches.
struct LocalJobsSection: View {
    let jobs: [LocalJob]
    let completed: Int          // finished so far in this burst
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(jobs.count > 1 ? "\(jobs.count) local models working" : "Local model working")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color.subtleText)
                // A batch fires many short jobs in a row; without a tally it looks
                // like one job stuck at a few seconds.
                if completed > 0 {
                    Text("· \(completed) done")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            ForEach(jobs) { job in
                LocalJobRow(job: job, now: now)
            }
        }
        .onReceive(ticker) { now = $0 }
    }
}

struct LocalJobRow: View {
    let job: LocalJob
    let now: Date

    // Recomputed against the ticking `now` rather than reading job.elapsed, so
    // SwiftUI actually re-renders each second.
    private var detail: String {
        var parts: [String] = []
        if job.isPreparing { parts.append("reading prompt") }
        if let rate = job.tokensPerSec, rate > 0 { parts.append("\(Int(rate.rounded())) tok/s") }
        parts.append(DateUtils.compactElapsed(now.timeIntervalSince(job.startedAt)))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.model)
                        .font(.callout).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(job.engine.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Ollama never logs prompt text, so this is LM Studio only.
                if Preferences.shared.showLocalTitles, let title = job.title {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(detail)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(Color.subtleText)
            }
        }
    }
}

// MARK: - Extra (pay-as-you-go) credits

struct ExtraUsageRow: View {
    let used: Double?
    let limit: Double?
    let currency: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Extra usage").font(.caption).foregroundStyle(Color.subtleText)
            Spacer()
            if let used {
                Text(summary(used))
                    .font(.caption).foregroundStyle(Color.subtleText).monospacedDigit()
            }
        }
    }

    // "$0.12 of $5.00 · $4.88 left" — or just the spend if there's no cap.
    private func summary(_ used: Double) -> String {
        guard let limit, limit > 0 else { return money(used) }
        let left = max(0, limit - used)
        return "\(money(used)) of \(money(limit)) · \(money(left)) left"
    }

    private func money(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

// MARK: - Status banner

struct StatusBannerView: View {
    let status: ClaudeStatus

    private var color: Color {
        if case .outage = status { return .red } else { return .orange }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(status.description).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
    }
}
