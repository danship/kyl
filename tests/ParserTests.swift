import Foundation

func parserTests() {
    // The current shape: a "limits" list with a kind per entry.
    let current = UsageParser.parseUsage(json("""
    {"limits":[
      {"kind":"session","percent":15,"resets_at":"2026-07-09T22:50:00.064762+00:00"},
      {"kind":"weekly_all","percent":3.4,"resets_at":"2026-07-15T16:00:00+00:00"},
      {"kind":"weekly_scoped","percent":2,"resets_at":"2026-07-15T16:00:00.065150+00:00",
       "scope":{"model":{"display_name":"Fable"}}},
      {"kind":"weekly_scoped","percent":40,"scope":{"surface":"design"}},
      {"kind":"something_new","percent":99},
      {"kind":"session_without_percent"}
    ]}
    """))
    expectEqual(current.session?.percent, 15, "session percent")
    expectEqual(current.session?.resetAt, DateUtils.parseISO("2026-07-09T22:50:00.064762+00:00"),
                "session reset, with fractions of a second")
    expectEqual(current.weeklyAll?.percent, 3, "weekly percent, rounded")
    expectEqual(current.weeklyAll?.resetAt, DateUtils.parseISO("2026-07-15T16:00:00Z"),
                "weekly reset, without fractions of a second")
    expectEqual(current.weeklyModels.map(\.label), ["Design", "Fable"],
                "per-model caps, fullest first, named by model or by surface")
    expectEqual(current.weeklyModels.map(\.key), ["weekly_scoped:Design", "weekly_scoped:Fable"],
                "per-model keys")
    expect(current.allMetrics.allSatisfy { $0.percent != 99 }, "an unknown kind is not shown")
    expect(!current.extraEnabled, "no spend block means no extra usage")

    // The older shape: top-level five_hour and seven_day objects.
    let older = UsageParser.parseUsage(json("""
    {"five_hour":{"utilization":61.6,"resets_at":"2026-07-09T22:50:00Z"},
     "seven_day":{"utilization":20,"resets_at":null}}
    """))
    expectEqual(older.session?.percent, 62, "older shape session")
    expectEqual(older.session?.key, "session", "older shape session key matches the current one")
    expectEqual(older.weeklyAll?.percent, 20, "older shape weekly")
    expect(older.weeklyAll?.resetAt == nil, "a null reset time is no reset time")

    // The limits list wins over the older objects when both are present.
    let both = UsageParser.parseUsage(json("""
    {"limits":[{"kind":"session","percent":10}], "five_hour":{"utilization":90}}
    """))
    expectEqual(both.session?.percent, 10, "limits list wins")

    // Extra usage, as money objects in minor units.
    let spend = UsageParser.parseUsage(json("""
    {"limits":[], "spend":{"enabled":true,
      "used":{"currency":"USD","amount_minor":12,"exponent":2},
      "cap":{"money":{"currency":"USD","amount_minor":500,"exponent":2}}}}
    """))
    expect(spend.extraEnabled, "spend enabled")
    expectEqual(spend.extraUsedCredits, 0.12, "spend used")
    expectEqual(spend.extraMonthlyLimit, 5.0, "spend cap from cap.money")
    expectEqual(spend.extraCurrency, "USD", "spend currency")
    let disabled = UsageParser.parseUsage(json("""
    {"spend":{"enabled":false,"used":3}}
    """))
    expect(!disabled.extraEnabled, "spend switched off is not shown")

    let empty = UsageParser.parseUsage(json("{}"))
    expect(empty.allMetrics.isEmpty, "an empty answer has no limits")
}
