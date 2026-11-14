import Foundation

func menuBarTitleTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var ws = WorkspaceUsage()
    ws.session = UsageMetric(key: "session", label: "Current Session",
                             percent: 42, resetAt: now.addingTimeInterval(3600))
    ws.weeklyAll = UsageMetric(key: "weekly_all", label: "All Models", percent: 71)
    ws.weeklyModels = [UsageMetric(key: "weekly_scoped:Fable", label: "Fable", percent: 12)]
    var other = WorkspaceUsage()
    other.session = UsageMetric(key: "session", label: "Current Session",
                                percent: 88, resetAt: now.addingTimeInterval(7200))

    func check(_ what: String, _ keys: [String], _ list: [WorkspaceUsage], _ want: String,
               labels: MenuBarLabelStyle = .full, line: UInt = #line) {
        let got = MenuBarTitle.make(workspaces: list, keys: keys, labels: labels,
                                    showEndTimes: false, now: now)
        expectEqual(got, want, what, line: line)
    }

    // The default selection reads as it did before the setting existed.
    check("default (session only)", ["session"], [ws], " 42% · 1h0m")
    check("session and week", ["session", "weekly_all"], [ws], " Session 42% · Week 71% · 1h0m")
    check("week and model, no countdown", ["weekly_all", "weekly_scoped:Fable"], [ws],
          " Week 71% · Fable 12%")
    let all = ["session", "weekly_all", "weekly_scoped:Fable"]
    check("all three, initials", all, [ws], " C:42% W:71% F:12% · 1h0m", labels: .initial)
    check("all three, percent only", all, [ws], " 42% · 71% · 12% · 1h0m", labels: .off)
    // One limit has nothing to tell apart, so every style reads the same.
    for style in MenuBarLabelStyle.allCases {
        check("one limit, \(style.rawValue)", ["session"], [ws], " 42% · 1h0m", labels: style)
    }
    check("nothing selected", [], [ws], "")
    check("limit the account doesn't have", ["weekly_scoped:Nope"], [ws], "")
    // The countdown follows the busiest session.
    check("two accounts", ["session"], [ws, other], " 42% · 88% · 2h0m")
    check("account missing the limit", ["weekly_all"], [ws, other], " 71% · —")
    check("no data yet", ["session"], [], " …")

    // Once a limit resets, the number read before it is wrong: it reads "…"
    // until the next check, and its countdown goes.
    var reset = ws
    reset.session?.resetAt = now.addingTimeInterval(-60)
    check("session has reset", ["session", "weekly_all"], [reset], " Session … · Week 71%")
    check("session has reset, initials", ["session", "weekly_all"], [reset], " C:… W:71%", labels: .initial)
    check("session has reset, alone", ["session"], [reset], " …")
}
