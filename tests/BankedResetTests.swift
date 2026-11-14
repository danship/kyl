import AppKit

func bankedResetTests() {
    // What claude.ai answered with ?cedar_ember=1, trimmed: two resets that
    // clear the week and one that gives back Fable's use.
    let answer = json("""
    {"limits": [{"kind": "weekly_all", "percent": 17, "resets_at": "2026-11-14T20:00:00+00:00"}],
     "cedar_ember": {"at_limit": false, "eligible": true, "ineligible_reason": null,
       "weekly_resets_at": "2026-11-14T20:00:00+00:00", "next_grant_id": "full-reset-2611",
       "grants": [
        {"id": "launch-2610-fable", "label": "New model launch: one Fable reset", "type": "full",
         "clears": ["seven_day_overage_included"], "gives_back_weekly": true, "resets_left": 1,
         "resets_total": 1, "ends_at": "2027-03-09T07:59:00+00:00", "paused": false, "usable_now": true},
        {"id": "free_reset_oct_2026", "label": "Free limit reset", "type": "weekly",
         "clears": ["seven_day", "seven_day_overage_included"], "gives_back_weekly": false,
         "resets_left": 1, "ends_at": "2026-12-16T04:59:00+00:00", "paused": false, "usable_now": true},
        {"id": "full-reset-2611", "label": "One full limit reset (November 2026)", "type": "weekly",
         "clears": ["seven_day", "seven_day_overage_included"], "gives_back_weekly": false,
         "resets_left": 1, "ends_at": "2026-12-10T22:00:00.000000+00:00", "paused": false,
         "usable_now": true}]}}
    """)
    let ws = UsageParser.parseUsage(answer)
    expectEqual(ws.bankedResets.map(\.label),
                ["One full limit reset (November 2026)", "Free limit reset", "New model launch: one Fable reset"],
                "every reset, soonest to expire first")
    expectEqual(ws.bankedResets.map(\.kind), [.weekly, .weekly, .fable],
                "a grant that gives back Fable's use is a Fable reset whatever its type says")
    expectEqual(ws.bankedResets.first?.endsAt, DateUtils.parseISO("2026-12-10T22:00:00Z"), "expiry read")
    expectEqual(ws.weeklyAll?.percent, 17, "the limits still parse beside them")

    let now = DateUtils.parseISO("2026-11-14T12:00:00Z")!
    expectEqual(ws.weeklyResetsLeft(at: now), 2, "two resets clear the week; the Fable one does not")
    expectEqual(ws.weeklyResetsLeft(at: DateUtils.parseISO("2026-12-12T00:00:00Z")!), 1,
                "a reset past its expiry no longer counts")
    expectEqual(ws.weeklyResetsLeft(at: DateUtils.parseISO("2027-01-01T00:00:00Z")!), 0, "nor once both expire")

    // Without the flag claude.ai says null, and an ineligible account none.
    expectEqual(UsageParser.parseUsage(json(#"{"cedar_ember": null}"#)).bankedResets, [], "null means none")
    expectEqual(UsageParser.parseUsage(json(#"{}"#)).bankedResets, [], "absent means none")
    expectEqual(UsageParser.bankedResets(json("""
    {"eligible": false, "ineligible_reason": "tier",
     "grants": [{"label": "x", "type": "weekly", "resets_left": 1}]}
    """)), [], "an ineligible account has none, whatever its grants say")

    // Grants that cannot be used now are left out.
    func grant(_ extra: String) -> [BankedReset] {
        UsageParser.bankedResets(json(#"{"eligible": true, "grants": [{"label": "R", "type": "weekly", "#
                                      + extra + "}]}"))
    }
    expectEqual(grant(#""resets_left": 0"#).count, 0, "none left")
    expectEqual(grant(#""resets_left": 1, "paused": true"#).count, 0, "paused")
    expectEqual(grant(#""resets_left": 1, "usable_now": false"#).count, 0, "not usable yet")
    expectEqual(grant(#""resets_left": 5000"#).count, 0, "an impossible count")
    expectEqual(grant(#""resets_left": 2"#).first?.left, 2, "a count of two")
    expectEqual(grant(#""resets_left": 1"#).first?.endsAt, nil, "no expiry")
    expect(grant(#""resets_left": 1"#).first?.isUsable(at: now) == true, "no expiry never expires")

    // The kind, from type, then from what a grant clears.
    func kind(_ fields: String) -> BankedReset.Kind {
        UsageParser.bankedKind(json("{" + fields + "}"))
    }
    expectEqual(kind(#""type": "session""#), .session, "type session")
    expectEqual(kind(#""type": "full""#), .full, "type full")
    expectEqual(kind(#""type": "turbo""#), .other("turbo"), "a type claude.ai added")
    expectEqual(kind(#""clears": ["five_hour"]"#), .session, "clears only the session")
    expectEqual(kind(#""clears": ["seven_day"]"#), .weekly, "clears only the week")
    expectEqual(kind(#""clears": ["five_hour", "seven_day"]"#), .full, "clears both")
    expectEqual(kind(#""type": "", "clears": ["seven_day"]"#), .weekly, "an empty type falls back to clears")
    expect(BankedReset(label: "", kind: .full, left: 1, endsAt: nil).clearsWeekly, "a full reset clears the week")
    expect(!BankedReset(label: "", kind: .session, left: 1, endsAt: nil).clearsWeekly, "a session one does not")
    expectEqual(UsageParser.bankedResets(json(#"{"eligible": true, "grants": [{"type": "session", "resets_left": 1}]}"#))
                    .first?.label, "Session reset", "a grant with no label is named by kind")

    // The glyphs carry each account's count.
    func account(_ id: String, resets: Int) -> WorkspaceUsage {
        var ws = WorkspaceUsage()
        ws.providerID = id
        ws.workspaceID = id
        ws.weeklyAll = UsageMetric(key: "weekly_all", label: "All Models", percent: 40,
                                   resetAt: now.addingTimeInterval(24 * 3600))
        ws.bankedResets = (0..<resets).map { _ in BankedReset(label: "R", kind: .weekly, left: 1, endsAt: nil) }
        return ws
    }
    let a = account("claude.a", resets: 2), b = account("claude.b", resets: 1)
    expectEqual(MenuBarRings.make(workspaces: [a, b], keys: ["weekly_all"], perAccount: true, now: now).map(\.banked),
                [2, 1], "one count per account")
    expectEqual(MenuBarRings.make(workspaces: [a, b], keys: ["weekly_all"], perAccount: true, banked: false,
                                  now: now).map(\.banked), [0, 0], "none when turned off")
    expectEqual(MenuBarRings.make(workspaces: [a, b], keys: ["weekly_all"], perAccount: false, now: now).map(\.banked),
                [0], "one glyph for several accounts carries none: a reset clears only its own account")
    var second = account("claude.a", resets: 1)
    second.workspaceID = "team"
    expectEqual(MenuBarRings.make(workspaces: [a, second], keys: ["weekly_all"], perAccount: false, now: now)
                    .map(\.banked), [3], "one account's workspaces add up")

    // The digit is drawn in the middle, inside the innermost ring.
    func ink(_ glyph: MenuBarGlyph) -> Int {
        let drawn = Drawn(ProgressRingImage.make(glyphs: [glyph]))
        let c = drawn.size.width / 2
        var count = 0
        for x in stride(from: c - 2.5, to: c + 2.5, by: 0.25) {
            for y in stride(from: c - 2.5, to: c + 2.5, by: 0.25) where !isClear(drawn.color(x, y)) { count += 1 }
        }
        return count
    }
    let two = [MenuBarRing(percent: 50), MenuBarRing(percent: 50)]
    expectEqual(ink(MenuBarGlyph(rings: two)), 0, "no digit, nothing in the middle")
    expect(ink(MenuBarGlyph(rings: two, banked: 1)) > 20, "a digit in the middle of two rings")
    let three = two + [MenuBarRing(percent: 50)]
    expect(ink(MenuBarGlyph(rings: three, banked: 2)) > ink(MenuBarGlyph(rings: three)),
           "a digit in the middle of three rings")
}
