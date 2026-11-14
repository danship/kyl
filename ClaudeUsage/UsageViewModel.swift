import Foundation
import Combine
import AppKit
import Network

class UsageViewModel: ObservableObject {
    // One entry per workspace the login belongs to (personal, work, …).
    @Published var workspaces: [WorkspaceUsage] = []

    @Published var isLoading = false
    // Accounts waiting on a sign-in. Per-account rather than one flag, because
    // with several sign-ins one expiring shouldn't make the others look broken.
    @Published var pendingLogins: [Account] = []
    @Published var errorMessage: String? = nil
    @Published var claudeStatus: ClaudeStatus = .operational
    // A check is owed but the Mac has no network, as it often has for a
    // moment after waking. It runs once macOS says the network is back.
    @Published private(set) var isWaitingForNetwork = false

    // Local models (Ollama / LM Studio) working right now — separate from the
    // claude.ai numbers above, since these have no quota, just a busy/idle state.
    @Published var localJobs: [LocalJob] = []

    // Jobs finished so far in the current burst — shown in the popover so a long
    // batch reads as progress rather than a single stuck-looking row.
    @Published var localCompleted = 0

    // Held slightly past the last job so a batch of short calls doesn't strobe.
    @Published var localBusy = false

    // Every enabled source of usage. Claude is the only one today; the list is
    // what makes adding a second one a matter of appending to it.
    private var providers: [UsageProvider] = []
    // Latest results per provider, merged into `workspaces` on every delivery.
    // Kept separately so one provider reporting doesn't erase another's numbers.
    private var resultsByProvider: [String: [WorkspaceUsage]] = [:]
    private var statusChecker: StatusChecker!
    private let localMonitor = LocalLLMMonitor()
    private let forecaster = UsageForecaster()
    private var refreshTimer: Timer?
    private var fetchWatchdog: Timer?
    // Fires at the next reset of any limit, when the numbers go out of date.
    private var resetTimer: Timer?
    // macOS says when the network comes and goes; the gate decides when a
    // check may run.
    private let pathMonitor = NWPathMonitor()
    private var gate = NetworkGate()
    private var wakeObserver: Any?
    private var activityToken: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    // Data older than this (with no successful refresh since) is considered stale.
    private let staleAfter: TimeInterval = 15 * 60

    func start() {
        // Other apps read what the popover shows from a JSON file, rewritten
        // whenever the numbers change or an account signs in or out. Account
        // renames and colors arrive as a change to the numbers: buildProviders
        // ends in rebuildWorkspaces.
        Publishers.CombineLatest($workspaces, $pendingLogins)
            .receive(on: RunLoop.main)
            .sink { workspaces, pending in
                // Nothing has loaded yet at launch; the last file written is
                // truer than an empty one until the first answer arrives.
                guard !workspaces.isEmpty || !pending.isEmpty else { return }
                UsageExport.write(workspaces: workspaces, accounts: AccountStore.shared.accounts,
                                  pending: pending)
            }
            .store(in: &cancellables)

        buildProviders()
        // Adding or removing an account rebuilds the provider list in place.
        AccountStore.shared.$accounts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.buildProviders() }
            .store(in: &cancellables)

        statusChecker = StatusChecker()
        statusChecker.onStatusReceived = { [weak self] status in
            DispatchQueue.main.async { self?.claudeStatus = status }
        }
        statusChecker.start()

        // Local model watcher. Publishes its own list and tells us when a job
        // ends so we can fire the "finished" notification.
        // Nothing here touches self — both collaborators are singletons — so no
        // capture is needed and there's no retain cycle to guard against.
        localMonitor.onRunFinished = { run in
            guard Preferences.shared.notifyLocalDone else { return }
            NotificationManager.shared.localRunFinished(run)
        }
        localMonitor.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] jobs in self?.localJobs = jobs }
            .store(in: &cancellables)
        localMonitor.$completedInRun
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.localCompleted = count }
            .store(in: &cancellables)
        localMonitor.$isBusy
            .receive(on: RunLoop.main)
            .sink { [weak self] busy in self?.localBusy = busy }
            .store(in: &cancellables)
        Preferences.shared.$showCodex
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.buildProviders() }
            .store(in: &cancellables)

        applyLocalPreference(Preferences.shared.watchLocalLLMs)
        Preferences.shared.$watchLocalLLMs
            .dropFirst()
            .sink { [weak self] on in self?.applyLocalPreference(on) }
            .store(in: &cancellables)

        // Ask macOS not to "App Nap" us — otherwise a backgrounded menu bar app
        // gets throttled and the refresh timer can quietly stop firing.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Periodically checking Claude usage")

        // The fetcher does its first fetch automatically once the page loads.
        scheduleRefreshTimer()

        // Reschedule if the user changes the refresh interval in Preferences.
        Preferences.shared.$refreshMinutes
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefreshTimer() }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: satisfied) }
        }
        pathMonitor.start(queue: .main)

        // After the Mac wakes from sleep, refresh right away — that's when the
        // parked page most often needs recovering. With no network yet, the
        // check waits for it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    // One provider per claude.ai sign-in.
    private func buildProviders() {
        let existing = Set(providers.compactMap { ($0 as? ClaudeProvider)?.account.id })
        let wanted = AccountStore.shared.accounts

        // Drop results for accounts that have gone away, or their numbers would
        // linger in the popover after the account was removed.
        let wantedIDs = Set(wanted.map(ClaudeProvider.id(for:)))
        resultsByProvider = resultsByProvider.filter { wantedIDs.contains($0.key) }
        pendingLogins.removeAll { account in !wanted.contains(where: { $0.id == account.id }) }

        // Renames keep the same id, so the loop below skips them. Update the
        // providers that already exist, and re-stamp the numbers they've
        // already delivered, so a new name shows immediately rather than after
        // the next fetch.
        for account in wanted {
            guard let p = providers.compactMap({ $0 as? ClaudeProvider })
                .first(where: { $0.account.id == account.id }),
                  p.account.name != account.name else { continue }
            p.account = account
            // A sign-in row in the popover carries the name too.
            if let i = pendingLogins.firstIndex(where: { $0.id == account.id }) {
                pendingLogins[i] = account
            }
            let key = ClaudeProvider.id(for: account)
            resultsByProvider[key] = resultsByProvider[key]?.map { ws in
                var copy = ws
                copy.providerName = account.name
                return copy
            }
        }

        for account in wanted where !existing.contains(account.id) {
            let provider = ClaudeProvider(account: account)
            let key = provider.id
            provider.onUsage = { [weak self] list in
                DispatchQueue.main.async {
                    self?.pendingLogins.removeAll { $0.id == account.id }
                    self?.apply(list, from: key)
                }
            }
            provider.onNeedsLogin = { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !self.pendingLogins.contains(where: { $0.id == account.id }) {
                        self.pendingLogins.append(account)
                    }
                    self.isLoading = false
                }
            }
            provider.onError = { [weak self] message in
                DispatchQueue.main.async {
                    self?.errorMessage = message   // keep last good numbers on screen
                    self?.isLoading = false
                }
            }
            provider.onNetworkFailure = { [weak self] in
                DispatchQueue.main.async { self?.networkFailed() }
            }
            provider.start()
            providers.append(provider)
        }
        providers.removeAll { p in
            guard let c = p as? ClaudeProvider else { return false }
            return !wanted.contains { $0.id == c.account.id }
        }
        buildCodexProvider()
        rebuildWorkspaces()
    }

    // Codex rides on the CLI's own sign-in, so there is no account to add:
    // it is on while the preference says so and the CLI is installed.
    private func buildCodexProvider() {
        let wanted = Preferences.shared.showCodex && CodexProvider.isInstalled
        let existing = providers.first { $0 is CodexProvider }
        if wanted, existing == nil {
            let provider = CodexProvider()
            let key = provider.id
            provider.onUsage = { [weak self] list in self?.apply(list, from: key) }
            provider.start()
            providers.append(provider)
        } else if !wanted, existing != nil {
            providers.removeAll { $0 is CodexProvider }
            resultsByProvider[CodexProvider.providerID] = nil
        }
    }

    // Call after a successful sign-in for one account.
    func signedIn(_ account: Account) {
        pendingLogins.removeAll { $0.id == account.id }
        refresh()
    }

    private func applyLocalPreference(_ enabled: Bool) {
        if enabled {
            localMonitor.start()
        } else {
            localMonitor.stop()
            localJobs = []
            localBusy = false
            localCompleted = 0
        }
    }

    // True while local work is in progress — drives the menu bar indicator.
    var isLocalBusy: Bool { localBusy }

    // Every account is waiting on a sign-in, so there is nothing to show but
    // the way back in.
    var allSignedOut: Bool {
        !pendingLogins.isEmpty && pendingLogins.count >= AccountStore.shared.accounts.count
            && !providers.contains { $0 is CodexProvider }
    }

    // Workspaces from accounts that are signed in. A signed-out account's last
    // numbers stay in the menu bar, but the popover shows a sign-in row in their
    // place rather than presenting hours-old numbers as current — and without
    // hiding the accounts that are still fine.
    var signedInWorkspaces: [WorkspaceUsage] {
        let pending = Set(pendingLogins.map(ClaudeProvider.id(for:)))
        return workspaces.filter { !pending.contains($0.providerID) }
    }

    // The account behind a provider id, read from the store rather than the
    // provider so a color picked in Preferences shows without waiting for a
    // fetch. Changing an account republishes `workspaces` (buildProviders ends
    // in rebuildWorkspaces), which is what redraws the popover.
    func account(forProvider providerID: String) -> Account? {
        AccountStore.shared.accounts.first { ClaudeProvider.id(for: $0) == providerID }
    }

    // Builds the refresh timer using the interval from Preferences, and adds it
    // in `.common` mode so it keeps firing even while a menu is open — and isn't
    // limited to the default run-loop mode that App Nap can suspend.
    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Preferences.shared.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        guard gate.checkRequested() else {
            isWaitingForNetwork = true
            return
        }
        check()
    }

    private func check() {
        isWaitingForNetwork = false
        isLoading = true
        providers.forEach { $0.fetch() }

        // Safety net: never let the spinner hang. If nothing comes back in 25s,
        // stop loading so the "stale" cue shows and the next cycle can retry.
        fetchWatchdog?.invalidate()
        let watchdog = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, self.isLoading else { return }
            self.isLoading = false
            if self.workspaces.isEmpty && self.errorMessage == nil {
                self.errorMessage = "No response from claude.ai — will retry."
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        fetchWatchdog = watchdog
    }

    private func networkChanged(online: Bool) {
        if gate.networkChanged(online: online) { check() }
    }

    // A check failed for want of a network. The last good numbers stay.
    private func networkFailed() {
        isLoading = false
        if gate.checkFailedForNetwork() {
            check()
        } else {
            isWaitingForNetwork = true
        }
    }

    // A check at the next reset, since that is when the numbers on screen
    // stop being true. Until it answers, a limit past its reset shows as
    // waiting rather than with its old number.
    private func scheduleResetCheck() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let next = WorkspaceUsage.nextReset(of: workspaces, after: Date()) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    // Kept for the single-account path; multi-account uses signedIn(_:).
    func loggedIn() {
        pendingLogins.removeAll()
        refresh()
    }

    // Store one provider's fresh data and attach a burn-rate forecast to each
    // limit. The forecaster keeps a separate history per workspace + metric, and
    // workspace ids are provider-prefixed, so histories can't collide.
    private func apply(_ list: [WorkspaceUsage], from providerID: String) {
        resultsByProvider[providerID] = list
        rebuildWorkspaces()
    }

    // Re-flatten every provider's latest results in provider order, so the list
    // doesn't reshuffle depending on which one answered first.
    private func rebuildWorkspaces() {
        let merged = providers.flatMap { resultsByProvider[$0.id] ?? [] }
        workspaces = merged.map { ws in
            var updated = ws
            let scope = ws.id
            updated.session = forecasted(ws.session, scope: scope)
            updated.weeklyAll = forecasted(ws.weeklyAll, scope: scope)
            updated.weeklyModels = ws.weeklyModels.map { forecasted($0, scope: scope) ?? $0 }
            return updated
        }
        // History can't be backfilled, so record before anything else can fail.
        UsageHistory.shared.record(workspaces)
        NotificationManager.shared.evaluate(workspaces)
        isLoading = false
        errorMessage = nil
        scheduleResetCheck()
    }

    private func forecasted(_ metric: UsageMetric?, scope: String) -> UsageMetric? {
        guard var m = metric else { return nil }
        m.forecast = forecaster.update(key: "\(scope).\(m.key)", percent: m.percent, resetAt: m.resetAt,
                                       windowLength: m.windowLength)
        return m
    }

    // MARK: - Menu bar helpers

    // The outer ring shows the highest session usage across workspaces…
    var ringPercent: Int? {
        workspaces.compactMap { $0.session?.percent }.max()
    }

    // …and the inner ring shows the highest weekly (all models) usage.
    var weeklyRingPercent: Int? {
        workspaces.compactMap { $0.weeklyAll?.percent }.max()
    }

    // Every limit currently reported, de-duplicated across workspaces and in the
    // order the popover draws them: the menu of what the menu bar can be told to
    // show. Per-model caps appear here as soon as the account has one.
    var menuBarChoices: [UsageMetric] { MenuBarRings.choices(workspaces) }

    // The glyphs to draw: one per account, each in its color, unless the
    // preference asks for one showing every account's fullest. A signed-out
    // account's glyph keeps its last numbers, dimmed.
    func menuBarGlyphs(now: Date = Date()) -> [MenuBarGlyph] {
        var tints: [String: String] = [:]
        for account in AccountStore.shared.accounts {
            tints[ClaudeProvider.id(for: account)] = account.color
        }
        return MenuBarRings.make(workspaces: workspaces, keys: Preferences.shared.menuBarRings,
                                 perAccount: Preferences.shared.menuBarRingsPerAccount,
                                 tints: tints,
                                 signedOut: Set(pendingLogins.map(ClaudeProvider.id(for:))),
                                 now: now)
    }

    // True if any limit anywhere is on pace to hit its cap — drives the ⚠ text.
    var isAnyAlerting: Bool {
        workspaces.contains { ws in ws.allMetrics.contains { $0.forecast.isAlerting } }
    }

    // Per-ring severity, so the outer (session) and inner (weekly) rings color
    // independently (and get the orange middle tier), instead of both jumping to
    // red when only one is in trouble. Takes the worst across workspaces.
    var sessionSeverity: Severity {
        workspaces.compactMap { $0.session }
            .map { severity(percent: $0.percent, forecast: $0.forecast) }.max() ?? .ok
    }
    var weeklySeverity: Severity {
        workspaces.compactMap { $0.weeklyAll }
            .map { severity(percent: $0.percent, forecast: $0.forecast) }.max() ?? .ok
    }

    var lastUpdated: Date? {
        workspaces.compactMap { $0.lastUpdated }.max()
    }

    // True when we have data but haven't successfully refreshed it in a while —
    // e.g. offline, logged out, or the API changed. Drives the "stale" cue.
    var isStale: Bool {
        guard let last = lastUpdated else { return false }
        return Date().timeIntervalSince(last) > staleAfter
    }

    var lastUpdatedText: String {
        guard let date = lastUpdated else { return "Never" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "Just now" }
        return "\(Int(secs / 60)) min ago"
    }

    deinit {
        refreshTimer?.invalidate()
        fetchWatchdog?.invalidate()
        resetTimer?.invalidate()
        pathMonitor.cancel()
        localMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
