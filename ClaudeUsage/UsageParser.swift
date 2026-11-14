import Foundation

// Turns claude.ai's usage JSON into a WorkspaceUsage. Kept separate from the
// web view so it's a pure function of its input, which tests/ checks against
// recorded answers. This is the piece most likely to break if claude.ai
// changes its API shape, so it's isolated on purpose.
enum UsageParser {

    static func parseUsage(_ usageDict: [String: Any]) -> WorkspaceUsage {
        var result = WorkspaceUsage()

        // The "limits" array is claude.ai's canonical usage structure. Each entry
        // has a `kind` (session / weekly_all / weekly_scoped), a `percent`, a
        // `resets_at`, and — for per-model caps — a `scope` naming the model.
        // Reading this array is what makes Fable and other models appear.
        if let limits = usageDict["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let pct = doubleValue(limit["percent"]) else { continue }
                let percent = Int(pct.rounded())
                let resetAt = DateUtils.parseISO(limit["resets_at"] as? String)
                let kind = limit["kind"] as? String ?? ""

                switch kind {
                case "session":
                    result.session = UsageMetric(key: "session", label: "Current Session",
                                                 percent: percent, resetAt: resetAt)
                case "weekly_all":
                    result.weeklyAll = UsageMetric(key: "weekly_all", label: "All Models",
                                                   percent: percent, resetAt: resetAt)
                case "weekly_scoped":
                    let name = scopedLabel(limit)
                    result.weeklyModels.append(
                        UsageMetric(key: "weekly_scoped:\(name)", label: name,
                                    percent: percent, resetAt: resetAt))
                default:
                    break
                }
            }
        }

        // Fallback for older API shape: if the limits array was missing, read the
        // top-level five_hour / seven_day objects instead.
        if result.session == nil, let obj = usageDict["five_hour"] as? [String: Any],
           let util = doubleValue(obj["utilization"]) {
            result.session = UsageMetric(key: "session", label: "Current Session",
                                         percent: Int(util.rounded()),
                                         resetAt: DateUtils.parseISO(obj["resets_at"] as? String))
        }
        if result.weeklyAll == nil, let obj = usageDict["seven_day"] as? [String: Any],
           let util = doubleValue(obj["utilization"]) {
            result.weeklyAll = UsageMetric(key: "weekly_all", label: "All Models",
                                           percent: Int(util.rounded()),
                                           resetAt: DateUtils.parseISO(obj["resets_at"] as? String))
        }

        // Extra pay-as-you-go usage lives under "spend" now (older API used
        // "extra_usage"). Only shown when the user has enabled it.
        if let spend = usageDict["spend"] as? [String: Any], (spend["enabled"] as? Bool) == true {
            result.extraEnabled = true
            result.extraUsedCredits = money(spend["used"])
            // The cap appears as `limit` (a money object) on some accounts, and on
            // others as a nested `cap: { money: …, credits: … }`. Try each shape.
            let cap = spend["cap"] as? [String: Any]
            result.extraMonthlyLimit = money(spend["limit"])
                ?? money(cap?["money"])
                ?? money(cap?["credits"])
            result.extraCurrency = (spend["used"] as? [String: Any])?["currency"] as? String

            // Temporary: log the raw block so we can confirm the exact shape on an
            // account that actually has spend enabled.
            if let json = try? JSONSerialization.data(withJSONObject: spend),
               let str = String(data: json, encoding: .utf8) {
                dlog("spend block: \(str)")
            }
        }

        result.bankedResets = bankedResets(usageDict["cedar_ember"])

        // Show the per-model bars in a stable order (highest usage first).
        result.weeklyModels.sort { $0.percent > $1.percent }
        return result
    }

    // Banked resets, from the `cedar_ember` object claude.ai includes when
    // asked with `?cedar_ember=1`:
    //
    //   {"eligible": true, "grants": [{"label": "Free limit reset", "type": "weekly",
    //     "clears": ["seven_day", "seven_day_overage_included"], "gives_back_weekly": false,
    //     "resets_left": 1, "ends_at": "2026-12-16T04:59:00+00:00", "paused": false,
    //     "usable_now": true, …}, …], …}
    //
    // Only resets that can be used now: a grant with none left, a paused one,
    // one with an impossible count and one claude.ai says is not usable yet
    // are left out. Soonest to expire first.
    static func bankedResets(_ value: Any?) -> [BankedReset] {
        guard let status = value as? [String: Any], status["eligible"] as? Bool == true,
              let grants = status["grants"] as? [[String: Any]] else { return [] }
        let resets = grants.compactMap { grant -> BankedReset? in
            guard let left = doubleValue(grant["resets_left"]).map({ Int($0) }),
                  // A count this large cannot be real, and adding such
                  // counts up could overflow.
                  left > 0, left <= 1000,
                  grant["paused"] as? Bool != true,
                  grant["usable_now"] as? Bool != false else { return nil }
            let kind = bankedKind(grant)
            let label = (grant["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(kindName(kind)) reset"
            return BankedReset(label: label, kind: kind, left: left,
                               endsAt: DateUtils.parseISO(grant["ends_at"] as? String))
        }
        return resets.sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
    }

    // What a grant gives back, as Claude Code works it out: a grant that gives
    // back the week's Fable use is a Fable reset whatever its type says; then
    // the type; then what it clears.
    static func bankedKind(_ grant: [String: Any]) -> BankedReset.Kind {
        if grant["gives_back_weekly"] as? Bool == true { return .fable }
        if let type = grant["type"] as? String, !type.isEmpty {
            switch type {
            case "session": return .session
            case "weekly":  return .weekly
            case "full":    return .full
            default:        return .other(type)
            }
        }
        let clears = grant["clears"] as? [String] ?? []
        let session = clears.contains("five_hour")
        let other = clears.contains { $0 != "five_hour" }
        return session && !other ? .session : other && !session ? .weekly : .full
    }

    static func kindName(_ kind: BankedReset.Kind) -> String {
        switch kind {
        case .session:         return "Session"
        case .weekly:          return "Weekly"
        case .full:            return "Full"
        case .fable:           return "Fable"
        case .other(let type): return type.capitalized
        }
    }

    // Pulls a friendly model name out of a weekly_scoped limit's `scope` object,
    // e.g. scope.model.display_name -> "Fable".
    static func scopedLabel(_ limit: [String: Any]) -> String {
        if let scope = limit["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any],
               let name = model["display_name"] as? String, !name.isEmpty {
                return name
            }
            if let surface = scope["surface"] as? String, !surface.isEmpty {
                return surface.capitalized
            }
        }
        return "Weekly (scoped)"
    }

    // claude.ai returns money either as a plain number or as an object like
    // { "currency": "USD", "amount_minor": 12, "exponent": 2 }  →  $0.12.
    // Returns the amount in major units (dollars), handling both shapes.
    static func money(_ value: Any?) -> Double? {
        if let d = doubleValue(value) { return d }
        guard let obj = value as? [String: Any],
              let minor = doubleValue(obj["amount_minor"]) else { return nil }
        let exponent = doubleValue(obj["exponent"]) ?? 2
        return minor / pow(10, exponent)
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
