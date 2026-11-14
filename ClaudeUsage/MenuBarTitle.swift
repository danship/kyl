import Foundation

// Builds the text beside the ring from whichever limits you picked in
// Preferences. Pure, so tests/ can check it without a menu bar.
enum MenuBarTitle {
    static func make(workspaces: [WorkspaceUsage], keys: [String],
                     labels: MenuBarLabelStyle, showEndTimes: Bool,
                     now: Date = Date()) -> String {
        guard !workspaces.isEmpty else { return " …" }
        let selected = Set(keys)
        // A label only earns its space once there's more than one number to
        // tell apart — one limit reads fine as a bare percentage, as it always
        // has. Past that it's a trade against menu bar width, which is what
        // the style is for.
        let style: MenuBarLabelStyle = selected.count > 1 ? labels : .off

        var parts: [String] = []
        for ws in workspaces {
            let shown = ws.allMetrics.filter { selected.contains($0.key) }
            if shown.isEmpty {
                // Keep a placeholder so several accounts still line up left to right.
                if workspaces.count > 1 { parts.append("—") }
                continue
            }
            parts.append(contentsOf: shown.map { $0.menuBarText(style, at: now) })
        }
        guard !parts.isEmpty else { return "" }   // nothing picked → ring only

        var title = " " + parts.joined(separator: style.separator)
        // Only the session gets a countdown. A weekly cap resets days out, and
        // "163h0m" next to a percentage isn't something anyone acts on.
        if selected.contains("session"),
           let reset = workspaces.compactMap({ $0.session })
               .max(by: { $0.percent < $1.percent })?.resetAt,
           reset.timeIntervalSince(now) > 0 {
            title += " · " + (showEndTimes ? DateUtils.shortClock(reset)
                                           : DateUtils.shortCountdown(to: reset, now: now))
        }
        return title
    }
}
