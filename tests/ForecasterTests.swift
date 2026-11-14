import Foundation

func forecasterTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600
    // A session that opened an hour ago, with four hours to go.
    let reset = now.addingTimeInterval(4 * hour)

    func verdict(_ percent: Int?, resetAt: Date?) -> ForecastVerdict {
        UsageForecaster().update(key: "org.session", percent: percent, resetAt: resetAt, now: now)
    }

    expectEqual(verdict(100, resetAt: reset), .atLimit, "at the limit")
    expectEqual(verdict(40, resetAt: nil), .unknown, "no reset time")
    expectEqual(verdict(0, resetAt: reset), .unknown, "nothing used")
    expectEqual(verdict(40, resetAt: now.addingTimeInterval(-60)), .unknown, "reset already passed")

    // 10% in the first hour of five projects to 50%.
    guard case .safe(let projected, _, _) = verdict(10, resetAt: reset) else {
        return expect(false, "10% in an hour should be safe")
    }
    expectEqual(projected, 50, "projected percent at the reset")

    // 40% in an hour runs out after another hour and a half, two and a half
    // hours before the reset.
    expectEqual(verdict(40, resetAt: reset), .willHit(beforeReset: 2.5 * hour, runsOutIn: 1.5 * hour),
                "on pace to run out")

    // 25% in an hour is over pace too, but below the floor that makes the
    // projection worth an alarm.
    expectEqual(verdict(25, resetAt: reset), .warmingUp, "over pace but too little used")

    // The window's length comes from the key: 30% with four hours left is an
    // hour into a session, far over pace, but nearly seven days into a week.
    let fourHoursLeft = now.addingTimeInterval(4 * hour)
    let session = UsageForecaster().update(key: "org.session", percent: 30, resetAt: fourHoursLeft, now: now)
    let weekly = UsageForecaster().update(key: "org.weekly_all", percent: 30, resetAt: fourHoursLeft, now: now)
    expect(session.isAlerting, "30% an hour into a session is alarming: \(session)")
    expect(!weekly.isAlerting, "30% near the end of a week is not: \(weekly)")
}
