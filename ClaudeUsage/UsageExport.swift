import Foundation

// What the popover shows, as a JSON file other apps can read:
//
//     ~/Library/Application Support/twoam.Tally/usage.json
//
// Rewritten whenever the numbers change or an account signs in or out, by
// replacing the file whole, so a reader never sees half of one and a watcher
// on the folder sees one change per update. `jq` reads it straight off the
// disk; a widget can watch it.
//
// The shape carries no version number: keys are only ever added, and a reader
// ignores the ones it doesn't know. Optional values are left out rather than
// written as null. Nothing sensitive goes in — no cookies, no tokens, and no
// local-model task titles, which are prompt text.
enum UsageExport {
    struct Document: Codable, Equatable {
        let updatedAt: Date
        let accounts: [AccountEntry]
    }

    struct AccountEntry: Codable, Equatable {
        let id: String              // stable: "claude.<uuid>", or "codex"
        let service: String         // "claude" or "codex"
        let name: String
        let color: String?          // "#RRGGBB" when the account has one
        let signedIn: Bool
        let workspaces: [WorkspaceEntry]
    }

    struct WorkspaceEntry: Codable, Equatable {
        let id: String?
        let name: String?
        let updatedAt: Date?
        let error: String?
        let limits: [Limit]
        let extraUsage: ExtraUsage?
        let bankedResets: [BankedResetEntry]?  // left out when there are none
    }

    struct BankedResetEntry: Codable, Equatable {
        let label: String
        let kind: String            // "session", "weekly", "full", "fable", or a kind claude.ai added
        let clearsWeekly: Bool
        let left: Int
        let endsAt: Date?
    }

    struct Limit: Codable, Equatable {
        let key: String             // "session", "weekly_all", "weekly_scoped:Fable", "codex_session", …
        let label: String
        let percent: Int
        let resetsAt: Date?
        let severity: String        // "ok", "warn" or "danger" — the bar's color
        let pace: String            // "unknown", "calculating", "onTrack", "willRunOut" or "atLimit"
        let projectedPercent: Int?  // where an on-track limit lands by its reset
        let runsOutAt: Date?        // when a limit on course to run out does
    }

    struct ExtraUsage: Codable, Equatable {
        let used: Double?
        let limit: Double?
        let currency: String?
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("twoam.Tally", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    // Every Claude account in the order Preferences lists them, signed in or
    // not, then any other service that has reported (Codex).
    static func document(workspaces: [WorkspaceUsage], accounts: [Account],
                         pending: [Account], now: Date = Date()) -> Document {
        let pendingIDs = Set(pending.map(\.id))
        var entries = accounts.map { account in
            let id = ClaudeProvider.id(for: account)
            return AccountEntry(id: id, service: "claude", name: account.name, color: account.color,
                                signedIn: !pendingIDs.contains(account.id),
                                workspaces: workspaces.filter { $0.providerID == id }.map { entry($0, now: now) })
        }
        let claudeIDs = Set(entries.map(\.id))
        var others: [String] = []
        for ws in workspaces where !claudeIDs.contains(ws.providerID) && !others.contains(ws.providerID) {
            others.append(ws.providerID)
        }
        for id in others {
            let mine = workspaces.filter { $0.providerID == id }
            entries.append(AccountEntry(id: id, service: id, name: mine.first?.providerName ?? id,
                                        color: nil,
                                        // A signed-out CLI reports a card with an error and no limits.
                                        signedIn: mine.contains { !$0.allMetrics.isEmpty },
                                        workspaces: mine.map { entry($0, now: now) }))
        }
        return Document(updatedAt: now, accounts: entries)
    }

    static func encode(_ document: Document) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(document)
    }

    static func write(workspaces: [WorkspaceUsage], accounts: [Account], pending: [Account]) {
        guard let data = encode(document(workspaces: workspaces, accounts: accounts, pending: pending))
        else { return }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            dlog("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func entry(_ ws: WorkspaceUsage, now: Date) -> WorkspaceEntry {
        WorkspaceEntry(id: ws.workspaceID, name: ws.workspaceName, updatedAt: ws.lastUpdated,
                       error: ws.error, limits: ws.allMetrics.map { limit($0, now: now) },
                       extraUsage: ws.extraEnabled
                           ? ExtraUsage(used: ws.extraUsedCredits, limit: ws.extraMonthlyLimit,
                                        currency: ws.extraCurrency)
                           : nil,
                       bankedResets: bankedResets(ws.bankedResets, now: now))
    }

    private static func bankedResets(_ resets: [BankedReset], now: Date) -> [BankedResetEntry]? {
        let usable = resets.filter { $0.isUsable(at: now) }
        guard !usable.isEmpty else { return nil }
        return usable.map { reset in
            let kind = switch reset.kind {
            case .session: "session"
            case .weekly: "weekly"
            case .full: "full"
            case .fable: "fable"
            case .other(let type): type
            }
            return BankedResetEntry(label: reset.label, kind: kind, clearsWeekly: reset.clearsWeekly,
                                    left: reset.left, endsAt: reset.endsAt)
        }
    }

    private static func limit(_ m: UsageMetric, now: Date) -> Limit {
        let level: String
        switch severity(percent: m.percent, forecast: m.forecast) {
        case .ok:     level = "ok"
        case .warn:   level = "warn"
        case .danger: level = "danger"
        }
        var pace = "unknown", projected: Int? = nil, runsOut: Date? = nil
        switch m.forecast {
        case .unknown:
            break
        case .warmingUp:
            pace = "calculating"
        case .safe(let p, _, _):
            pace = "onTrack"; projected = p
        case .willHit(_, let runsOutIn):
            pace = "willRunOut"; runsOut = now.addingTimeInterval(runsOutIn)
        case .atLimit:
            pace = "atLimit"
        }
        return Limit(key: m.key, label: m.label, percent: m.percent, resetsAt: m.resetAt,
                     severity: level, pace: pace, projectedPercent: projected, runsOutAt: runsOut)
    }
}
