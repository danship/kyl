# Ideas from quotabar

[quotabar](https://github.com/Hixie/contraptions/tree/main/quotabar) is a
small macOS menu bar indicator by Ian Hickson. For each of several Claude
accounts it shows one circle. The circle's outer ring fills as the week
passes, and its inner disc fills as the weekly quota is used. It is about
1,300 lines of Swift with 1,400 lines of tests, and it reads only the weekly
limit.

KYL already does more than quotabar does: it shows the session, weekly and
per-model limits, extra usage, history, forecasts, service status, Codex and
local models. quotabar is better at a few narrow things. This document lists
those things and proposes how KYL could adopt each one, most valuable first.

Items 1 to 4 and 7 are built. Items 5, 6 and 8 are not started.

## 1. One glyph per account in the menu bar

**What quotabar does.** It draws a 16-point circle for each account, side by
side, so the menu bar answers "which account has room?" without a click.

**What KYL does.** KYL draws one set of rings. Each ring shows the highest
percentage of that limit across all accounts, and the worst color. With two
accounts at 95% and 10% of the week, the menu bar shows 95%. The account with
room is hidden, and choosing an account is the decision the meter is for.

**Proposal.** Add a menu bar style, "One per account", that draws a small
ring glyph for each signed-in account in that account's color, in the order
Preferences lists them. Each glyph shows the limits the user picked, as the
single glyph does today. The text beside the glyphs follows the same
setting: one percentage per account, or none. The current combined rings
stay the default for one account. This change lives in
`ProgressRingIcon.swift` (draw several glyphs into one image) and
`UsageViewModel.menuBarRings` (one ring set per account instead of the
maximum).

## 2. Show how much of the window has passed, next to how much is used

**What quotabar does.** The outer ring shows how far through the week it
is. The disc shows how much quota is used. When the disc is further round
than the ring, the account is using its quota faster than time is passing.
The reader compares two angles, and needs no color rule or forecast to
trust.

**What KYL does.** KYL shows how much is used, and says whether that is on
pace through color (blue, orange, red) and through the forecast text in the
popover. The color is a judgment the reader has to take on trust, and it
does not say how far ahead or behind the account is.

**Proposal.** Draw a short tick across each ring at the fraction of that
limit's window that has passed: five hours for the session, seven days for
the weekly and per-model limits. A ring's fill past its tick is quota spent
ahead of time. The window start is already known: KYL shows "Opened 12:10 PM
· resets 5:10 PM", so the fraction is `(now − opened) / (resets − opened)`.
Start with the popover's account rings, where there is room; try the menu
bar glyph afterwards, where a tick at 2 points of stroke may be too small to
read. Keep the colors.

## 3. Treat numbers from before a reset as wrong, and check at the reset

**What quotabar does.** When a limit's reset time passes before the next
successful check, quotabar draws that account faintly, because the numbers
it holds are known to be out of date, not merely old.

**What KYL does.** KYL dims the whole menu bar item when the last fetch is
more than 15 minutes old. A session that reset two minutes ago still shows
its old 90% until the next scheduled fetch, which can be several minutes
away.

**Proposal.** Two changes.

- Schedule a fetch for the earliest `resetAt` across all accounts and
  limits, in addition to the regular timer. KYL then learns about a reset
  when it happens instead of polling until it notices.
- Until that fetch returns, draw a limit whose `resetAt` has passed as
  stale: a dimmed ring in the menu bar and "Reset at 5:10 PM, checking"
  in the popover, in place of its old percentage.

## 4. Wait for the network after waking, instead of failing

**What quotabar does.** It watches the network with macOS's path monitor
(`NWPathMonitor`). A check asked for while the Mac is offline waits until
the Mac is online. A check that fails for a network reason (no connection,
lost connection, host not found, timed out) runs again as soon as macOS
reports the network back.

**What KYL does.** KYL refreshes as soon as the Mac wakes, which is often
before Wi-Fi has reconnected. A fetch that gets no answer in 25 seconds ends
with "No response from claude.ai — will retry", and the next try is the next
timer tick.

**Proposal.** Add a path monitor to `UsageViewModel`. On wake, and on every
timer tick, fetch only when the path is satisfied; otherwise remember that a
fetch is owed and run it when the path becomes satisfied. Have
`UsageFetcher` report network failures from the page's `fetch()` calls as
their own kind of error, so the view model can hold them for the network
instead of showing them. The 25-second watchdog can then shrink to the case
it was written for, a page that never answers.

## 5. Banked resets, if the claude.ai endpoint reports them

**What quotabar does.** Anthropic gives some accounts banked resets: credits
that clear a limit early. quotabar reads them from the `cedar_ember` part of
the usage answer, counts the ones that clear the weekly limit, and shows the
count as a digit in the middle of the circle. The menu lists each kind with
how many are left and when they expire. It never uses them.

**What KYL does.** Nothing. KYL's parser does not read `cedar_ember`.

**Caveat.** quotabar reads `api.anthropic.com/api/oauth/usage` with
`?cedar_ember=1`, and its README says the server reports banked resets only
to surfaces it offers them on, telling surfaces apart by request headers.
KYL reads `claude.ai/api/organizations/{id}/usage` with the site's own
cookies. Whether that answer carries banked resets is not known (a guess
either way).

**Proposal.** First, log the raw usage answer for each signed-in account
once, and look for `cedar_ember` or anything like it. If the answer has it,
parse it as quotabar does (its `parseBanked` function sorts resets into
session, weekly, Fable-only and full resets the way Claude Code does) and
show the count of resets that clear the weekly limit as a small badge on the
account's ring, with the list and expiry dates in the account's detail view
and in `usage.json`. If the answer does not have it, stop there: see "Not
proposed" below.

## 6. Error messages that name the field that changed

**What quotabar does.** When the usage answer does not decode, the menu says
which field broke and how: "seven_day.resets_at is not text", "the usage
answer has no weekly quota".

**What KYL does.** KYL shows "Couldn't load usage". The README says the fix
is usually a change to `UsageParser.swift`, but the person making it has to
find out what changed.

**Proposal.** When `UsageParser` finds no limit it recognises, or a limit
with a missing or unreadable field, return a reason naming the field
(`limits[2].resets_at is missing`, `no limit has kind "session"`), and show
it in the popover's error state and in the detail view, under the existing
message.

## 7. A test target

**What quotabar does.** Its tests cover everything but the program's entry
point. They decode recorded answers, check ordering and reset arithmetic,
draw the circles into bitmaps and check the pixels, and drive the menu.

**What KYL does.** KYL has no tests. The parser, the forecaster, the menu bar
title and the ring drawing are all pure enough to test, and each fails
silently: a wrong percentage or a missing ring is not an error.

**Proposal.** Add a unit test target with, to start: the parser against the
sample answer already written in `UsageParser.swift`'s comments and against
the older `five_hour`/`seven_day` shape; the forecaster's on-pace, warming-up
and will-run-out cases; `MenuBarTitle.make` for each label style; and
`ProgressRingImage.make`, drawn into a bitmap, checking that a ring at 50%
covers the right half. Items 1 to 3 change exactly this code, so the tests
should land first.

## 8. Order accounts by when their week resets (optional)

**What quotabar does.** It orders accounts by when in the week each one's
weekly quota resets, counting from Monday midnight in local standard time,
so the order does not change at daylight saving changes. It remembers each
account's last known reset time so the order holds across restarts.

**Proposal.** Offer "Order by weekly reset" in Preferences → Accounts,
beside the current manual order. For someone rotating between accounts, the
leftmost account is then the next to reset. quotabar's `weekOffset` function
can be reused as it stands.

## Not proposed

- **Signing in the way Claude Code does.** quotabar signs in through the
  browser with OAuth, as Claude Code's registered client, asking only for
  the scope that reads a profile. It keeps tokens of its own and sends
  Claude Code's `User-Agent` and `x-app` headers. That removes KYL's hidden
  web view and is the only known way to get banked resets. It also presents
  the app to Anthropic as Claude Code, which quotabar's own README says
  Anthropic's terms may not allow. KYL already depends on one undocumented
  endpoint; adding an impersonated client makes the risk larger, not
  smaller.
- **Weekly-only display.** quotabar drops the session and per-model limits
  to fit one circle per account. KYL's users pick the limits they want, and
  item 1 keeps that choice.
- **A launchd agent and a single-instance lock.** quotabar needs the lock
  because two copies would spend each other's refresh tokens. KYL's cookies
  have no such problem, and it already starts at login as a login item.
