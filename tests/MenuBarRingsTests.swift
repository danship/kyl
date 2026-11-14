import Foundation

func menuBarRingsTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    // How much of a window has passed.
    let session = UsageMetric(key: "session", label: "Current Session", percent: 30,
                              resetAt: now.addingTimeInterval(4 * hour))
    expectClose(session.elapsedFraction(at: now), 0.2, "one hour into a five-hour session")
    let week = UsageMetric(key: "weekly_all", label: "All Models", percent: 30,
                           resetAt: now.addingTimeInterval(3.5 * 24 * hour))
    expectClose(week.elapsedFraction(at: now), 0.5, "half way through a week")
    let codex = UsageMetric(key: "codex_session", label: "Session", percent: 0,
                            resetAt: now.addingTimeInterval(hour), windowLength: 2 * hour)
    expectClose(codex.elapsedFraction(at: now), 0.5, "a window the service gives its own length")
    expect(UsageMetric(key: "session", label: "", percent: 1).elapsedFraction(at: now) == nil,
           "no reset time, no fraction")
    expectClose(session.elapsedFraction(at: now.addingTimeInterval(9 * hour)), 1, "clamped past the reset")

    // Whether the reset has passed.
    expect(!session.hasReset(at: now), "a reset still to come has not passed")
    expect(session.hasReset(at: now.addingTimeInterval(4 * hour)), "a reset passes at its time")
    expect(!UsageMetric(key: "session", label: "", percent: 1).hasReset(at: now), "no reset time never resets")

    // Two accounts: one nearly out, one with room.
    func account(_ id: String, session percent: Int, week weekly: Int) -> WorkspaceUsage {
        var ws = WorkspaceUsage()
        ws.providerID = id
        ws.workspaceID = id
        ws.session = UsageMetric(key: "session", label: "Current Session", percent: percent,
                                 resetAt: now.addingTimeInterval(4 * hour))
        ws.weeklyAll = UsageMetric(key: "weekly_all", label: "All Models", percent: weekly,
                                   resetAt: now.addingTimeInterval(3.5 * 24 * hour))
        return ws
    }
    let busy = account("claude.a", session: 95, week: 50)
    let idle = account("claude.b", session: 10, week: 20)
    let keys = ["weekly_all", "session"]

    let each = MenuBarRings.make(workspaces: [busy, idle], keys: keys, perAccount: true,
                                 tints: ["claude.b": "#3366FF"], signedOut: ["claude.b"], now: now)
    expectEqual(each.count, 2, "a glyph per account")
    expectEqual(each.map { $0.rings.map(\.percent) }, [[95, 50], [10, 20]],
                "each account's own numbers, session outermost whatever order the keys are stored in")
    expectEqual(each.map(\.tint), [nil, "#3366FF"], "each account's color")
    expectEqual(each.map(\.dimmed), [false, true], "a signed-out account is dimmed")
    expectEqual(each[0].rings[0].severity, .danger, "95% of a session is danger")
    expectEqual(each[1].rings[0].severity, .ok, "the account with room is not colored by the other")
    expectClose(each[0].rings[0].elapsed, 0.2, "the session ring carries its window's progress")
    expectClose(each[0].rings[1].elapsed, 0.5, "and the week ring its own")

    let combined = MenuBarRings.make(workspaces: [busy, idle], keys: keys, perAccount: false, now: now)
    expectEqual(combined.count, 1, "one glyph for every account")
    expectEqual(combined[0].rings.map(\.percent), [95, 50], "each limit at its fullest")

    // Two workspaces in one account share its glyph.
    var work = account("claude.a", session: 40, week: 70)
    work.workspaceID = "work"
    let shared = MenuBarRings.make(workspaces: [busy, work, idle], keys: keys, perAccount: true, now: now)
    expectEqual(shared.map { $0.rings.map(\.percent) }, [[95, 70], [10, 20]],
                "an account's workspaces combine; the order follows the first workspace of each")

    // A limit that has reset since it was read is stale, not danger.
    let later = now.addingTimeInterval(5 * hour)
    let afterReset = MenuBarRings.make(workspaces: [busy], keys: keys, perAccount: true, now: later)
    expect(afterReset[0].rings[0].stale, "the session has reset")
    expectEqual(afterReset[0].rings[0].severity, .ok, "a stale ring is not colored as danger")
    expect(afterReset[0].rings[0].elapsed == nil, "a stale ring has no notch")
    expect(!afterReset[0].rings[1].stale, "the week has not reset")

    // An account without a limit keeps the ring's place, empty.
    var codexOnly = WorkspaceUsage()
    codexOnly.providerID = "codex"
    codexOnly.weeklyAll = UsageMetric(key: "weekly_all", label: "Week", percent: 5)
    let mixed = MenuBarRings.make(workspaces: [busy, codexOnly], keys: keys, perAccount: true, now: now)
    expectEqual(mixed[1].rings.map(\.percent), [nil, 5], "a missing limit is an empty ring in its place")

    // Limits nobody reports are left out, and three is the most.
    let none = MenuBarRings.make(workspaces: [busy], keys: ["weekly_scoped:Nope"], perAccount: true, now: now)
    expect(none[0].rings.isEmpty, "a limit no account reports gets no ring")

    // The next reset, when the numbers go out of date.
    expectEqual(WorkspaceUsage.nextReset(of: [busy, idle], after: now), now.addingTimeInterval(4 * hour),
                "the earliest reset to come")
    expectEqual(WorkspaceUsage.nextReset(of: [busy], after: now.addingTimeInterval(5 * hour)),
                now.addingTimeInterval(3.5 * 24 * hour), "a reset already passed is skipped")
    expect(WorkspaceUsage.nextReset(of: [], after: now) == nil, "nothing to wait for")
}
