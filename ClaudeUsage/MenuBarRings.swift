import Foundation

// What the menu bar's rings show, worked out from the usage alone so tests/
// can check it without drawing. ProgressRingImage turns the result into the
// picture.

extension UsageMetric {
    /// How long this limit's window lasts: what the service says, or else
    /// what Claude's limits are known to last.
    var window: TimeInterval { windowLength ?? UsageForecaster.windowLength(forKey: key) }

    /// How much of the window has passed, from 0 just after it opens to 1 at
    /// the reset. Nil without a reset time.
    func elapsedFraction(at now: Date) -> Double? {
        guard let resetAt else { return nil }
        return min(max(1 - resetAt.timeIntervalSince(now) / window, 0), 1)
    }

    /// Whether the reset has passed since these numbers were read, which
    /// makes them wrong rather than merely old: the limit has started again.
    func hasReset(at now: Date) -> Bool {
        resetAt.map { $0 <= now } ?? false
    }
}

extension WorkspaceUsage {
    /// The earliest reset still to come across `workspaces`, when the
    /// numbers next go out of date.
    static func nextReset(of workspaces: [WorkspaceUsage], after now: Date) -> Date? {
        workspaces.flatMap(\.allMetrics).compactMap(\.resetAt).filter { $0 > now }.min()
    }
}

/// One ring in the menu bar.
struct MenuBarRing: Equatable {
    /// Nil when this account has no such limit; the ring keeps its place.
    var percent: Int?
    var severity: Severity = .ok
    /// How much of the limit's window has passed, for the notch.
    var elapsed: Double? = nil
    /// The limit has reset since it was read, so its number is wrong.
    var stale = false
}

/// One account's rings, outermost first, or every account's together.
struct MenuBarGlyph: Equatable {
    var rings: [MenuBarRing]
    /// The account's color, "#RRGGBB", for the ring's track.
    var tint: String? = nil
    /// The account is waiting on a sign-in, so its numbers are old.
    var dimmed = false
}

enum MenuBarRings {
    /// Every limit the workspaces report, once each, in the order the
    /// popover lists them: what the menu bar can be told to show.
    static func choices(_ workspaces: [WorkspaceUsage]) -> [UsageMetric] {
        var seen = Set<String>()
        return workspaces.flatMap(\.allMetrics).filter { seen.insert($0.key).inserted }
    }

    /// The glyphs to draw: one per account when `perAccount`, in the order the
    /// workspaces come, or one for them all, showing each limit at its
    /// fullest. Each glyph has a ring for each of `keys` the accounts report,
    /// at most three, in the popover's order, so the outer ring always means
    /// the same limit. `tints` and `signedOut` are keyed by provider id.
    static func make(workspaces: [WorkspaceUsage], keys: [String], perAccount: Bool,
                     tints: [String: String] = [:], signedOut: Set<String> = [],
                     now: Date) -> [MenuBarGlyph] {
        let wanted = Set(keys)
        let shown = choices(workspaces).map(\.key).filter { wanted.contains($0) }.prefix(3)
        guard perAccount else {
            return [MenuBarGlyph(rings: shown.map { ring(for: $0, in: workspaces, now: now) })]
        }
        var order: [String] = []
        for ws in workspaces where !order.contains(ws.providerID) { order.append(ws.providerID) }
        return order.map { provider in
            let own = workspaces.filter { $0.providerID == provider }
            return MenuBarGlyph(rings: shown.map { ring(for: $0, in: own, now: now) },
                                tint: tints[provider], dimmed: signedOut.contains(provider))
        }
    }

    /// The ring for one limit: its fullest reading among `workspaces`, colored
    /// by the worst, with a limit that has reset since drawn as stale.
    private static func ring(for key: String, in workspaces: [WorkspaceUsage], now: Date) -> MenuBarRing {
        let matching = workspaces.flatMap(\.allMetrics).filter { $0.key == key }
        guard let fullest = matching.max(by: { $0.percent < $1.percent }) else {
            return MenuBarRing(percent: nil)
        }
        if fullest.hasReset(at: now) {
            return MenuBarRing(percent: fullest.percent, stale: true)
        }
        let worst = matching.filter { !$0.hasReset(at: now) }
            .map { severity(percent: $0.percent, forecast: $0.forecast) }.max() ?? .ok
        return MenuBarRing(percent: fullest.percent, severity: worst,
                           elapsed: fullest.elapsedFraction(at: now))
    }
}
