import AppKit
import SwiftUI
import Combine
import WebKit   // WKWebsiteDataStore, for per-account sign-in

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginWindow: NSWindow?
    private var settingsWindow: NSWindow?
    let viewModel = UsageViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var labelTimer: Timer?

    // Sparkle quits the app to swap the bundle, and a normal Quit is no
    // different. Either way the last few seconds of history are still sitting
    // in a pending write, so force it out before we go.
    func applicationWillTerminate(_ notification: Notification) {
        UsageHistory.shared.flush()
    }

    // Reclaim the container left behind when the App Sandbox was removed.
    //
    // Sandboxed builds kept everything under ~/Library/Containers/<bundle id>.
    // Turning the sandbox off (needed to read Ollama's log and run `lms`) moved
    // all of that to the normal locations and stranded the old copy — half a
    // gigabyte on a machine that had been running Juicage since July, which
    // nothing will ever read again.
    //
    // Guarded on actually being unsandboxed: build with ENABLE_APP_SANDBOX=YES
    // and that directory is the live home folder, so deleting it would destroy
    // the running app's own data.
    private func reclaimOrphanedContainer() {
        guard !NSHomeDirectory().contains("/Library/Containers/") else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let key = "didReclaimSandboxContainer"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)

        DispatchQueue.global(qos: .utility).async {
            defer { UserDefaults.standard.set(true, forKey: key) }
            guard FileManager.default.fileExists(atPath: container.path) else { return }
            do {
                try FileManager.default.removeItem(at: container)
                dlog("Reclaimed orphaned sandbox container")
            } catch {
                dlog("Could not reclaim container: \(error.localizedDescription)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reclaimOrphanedContainer()

        NSApp.setActivationPolicy(.accessory)
        NotificationManager.shared.requestAuthorization()
        _ = UpdateController.shared     // starts Sparkle's scheduled check, if present
        AccountStore.shared.syncChromeColors()
        setupStatusBar()
        setupPopover()
        observeViewModel()
        viewModel.start()

        // Let the popover's "Sign In" button (re)open the login window.
        NotificationCenter.default.addObserver(self, selector: #selector(handleOpenLogin),
                                               name: .openLogin, object: nil)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.title = " …"
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 240)
        popover.behavior = .transient
        // Always dark: the popover is read against whatever is behind the
        // menu bar, and a translucent light panel over a busy desktop let
        // the wallpaper compete with the numbers. PopoverView lays its own
        // near-opaque charcoal behind the content; this keeps the arrow,
        // the controls and the system text colors on the same side.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(viewModel)
        )
    }

    private func observeViewModel() {
        // Rebuild the menu bar whenever the usage data or Claude's status changes.
        // A 60s timer also refreshes it so the countdown ticks down between the
        // 3-minute data fetches.
        Publishers.CombineLatest(viewModel.$workspaces, viewModel.$claudeStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateStatusBar()
        }
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer

        // A local model starting or finishing changes the menu bar dot.
        viewModel.$localJobs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        // Redraw the menu bar immediately when the "show percentage" setting changes.
        Preferences.shared.$showMenuBarText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        Preferences.shared.$showEndTimes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        Preferences.shared.$menuBarMetrics
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        Preferences.shared.$menuBarLabelStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        Preferences.shared.$menuBarRings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        Preferences.shared.$menuBarRingsPerAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)
        // A sign-in starting or finishing dims or restores that account's glyph.
        viewModel.$pendingLogins
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBar() }
            .store(in: &cancellables)

        // Open the sign-in window for whichever account needs one. With several
        // accounts they queue rather than fighting over a single window.
        viewModel.$pendingLogins
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                guard let self, let account = pending.first else { return }
                if self.loginWindow == nil {
                    self.statusItem.button?.title = " Sign in"
                    self.showLoginWindow(for: account)
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusBar() {
        guard let button = statusItem.button else { return }

        let alert = viewModel.isAnyAlerting
        let title = MenuBarTitle.make(workspaces: viewModel.workspaces,
                                      keys: Preferences.shared.menuBarMetrics,
                                      labels: Preferences.shared.menuBarLabelStyle,
                                      showEndTimes: Preferences.shared.showEndTimes)

        // The ring is the primary indicator; the outage dot only appears on top
        // of it when Claude itself is having problems.
        let text = Preferences.shared.showMenuBarText && !title.isEmpty
            ? (alert ? "\(title) ⚠" : title)
            : ""                // ring only (saves menu bar space, e.g. on notched Macs)

        // A green dot trails the text while a local model is generating. It's
        // deliberately separate from the rings: local models have no quota, just
        // a busy state, so it says "working" and nothing more.
        if viewModel.isLocalBusy {
            button.attributedTitle = busyTitle(text)
        } else {
            button.title = text
        }
        button.image = ringImage()
        button.imagePosition = .imageLeft

        // Dim the whole item when the data hasn't refreshed in a while, so old
        // numbers don't look live.
        button.appearsDisabled = viewModel.isStale
    }

    // Menu bar text with a green "busy" dot appended, sized to sit level with
    // the numbers rather than dominating them.
    private func busyTitle(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text.isEmpty ? "" : "\(text) ")
        out.append(NSAttributedString(string: "●", attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.systemFont(ofSize: 9),
        ]))
        return out
    }

    // The rings, with a corner badge when claude.ai is unwell.
    //
    // This used to replace the rings with a status dot, which threw away the
    // number you still needed — degraded service doesn't stop you spending, and
    // that's precisely when you want to see where you stand.
    private func ringImage() -> NSImage {
        ProgressRingImage.make(glyphs: viewModel.menuBarGlyphs(),
                               status: viewModel.claudeStatus)
    }

    private func statusDotImage(for status: ClaudeStatus) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let color: NSColor
            if case .outage = status { color = .systemRed } else { color = .systemOrange }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()
            return true
        }
    }

    // MARK: - Click handling

    // Left-click opens the popover; right-click shows the context menu.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            AccountStore.shared.syncChromeColors()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // "KYL 1.9.2" — disabled, purely a label. Version confusion is the first
    // thing that comes up whenever someone reports a problem, so it's worth the
    // zero clicks it takes to read it here.
    private var versionMenuItem: NSMenuItem {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let item = NSMenuItem(title: "KYL \(short)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(versionMenuItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(menuRefresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let openPage = NSMenuItem(title: "Open Usage Page in Browser", action: #selector(menuOpenPage), keyEquivalent: "")
        openPage.target = self
        menu.addItem(openPage)

        let signIn = NSMenuItem(title: "Sign in to Claude…", action: #selector(menuSignIn), keyEquivalent: "")
        signIn.target = self
        menu.addItem(signIn)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launch)

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(menuPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // KYL takes no in-app updates (UpdateController), so this opens the
        // releases of Juicage, the app it forks, to see what is new there.
        let update = NSMenuItem(title: "Juicage Releases…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = UpdateController.shared.canCheckForUpdates
        menu.addItem(update)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About KYL", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit KYL", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach the menu just for this click, then detach so left-click still
        // opens the popover next time.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { viewModel.refresh() }
    @objc private func menuSignIn()  { showLoginWindow(for: nil) }
    @objc private func menuQuit()    { NSApp.terminate(nil) }

    @objc private func menuOpenPage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuAbout() {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        // An accessory app has no menu bar of its own, so the panel opens behind
        // everything unless we activate first.
        NSApp.activate(ignoringOtherApps: true)
        // The panel also shows Credits.html from the bundle: the full MIT
        // notice of Juicage, which KYL forks and must carry in every copy.
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "KYL",
            .applicationVersion: short,
            .version: build,
            .init(rawValue: "Copyright"): "An unofficial usage meter for Claude and Codex.\nBased on Juicage © 2026 Ryan Barnett, MIT License.\nNot affiliated with Anthropic or OpenAI.",
        ])
    }

    @objc private func menuCheckForUpdates() {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func menuToggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func menuPreferences() {
        AccountStore.shared.syncChromeColors()
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView().environmentObject(viewModel))
            let win = NSWindow(contentViewController: hosting)
            win.title = "KYL Preferences"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Which account the open sign-in window belongs to.
    private var loginAccount: Account?

    // With no account named (the popover's Sign In, the menu's "Sign in to
    // Claude…"), the one to sign in is whichever is waiting on it.
    func showLoginWindow(for account: Account? = nil) {
        let target = account ?? viewModel.pendingLogins.first ?? AccountStore.shared.accounts.first
        // The window is bound to one account's cookie jar. Asked for another
        // while it's open, replace it rather than bring the old one forward —
        // otherwise the sign-in lands in one jar and is credited to the other.
        // Closing runs windowWillClose, which clears loginWindow.
        if loginWindow != nil, loginAccount?.id != target?.id {
            loginWindow?.close()
        }
        loginAccount = target
        // The app stays menu-bar-only while signing in, with no Dock icon. If
        // the window slips behind another app, the popover's Sign In and the
        // menu's "Sign in to Claude…" bring it back.
        // NOTE: deliberately NOT a floating window — a WKWebView at an elevated
        // window level doesn't reliably receive clicks.

        if loginWindow == nil {
            let store = loginAccount.map { AccountStore.dataStore(for: $0) } ?? .default()
            let view = LoginView(dataStore: store, onLoggedIn: { [weak self] in
                self?.finishLogin()
            })
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Sign in to Claude"
            win.styleMask = [.titled, .closable, .resizable]
            win.setContentSize(NSSize(width: 480, height: 640))
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            loginWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
        // Activation is a request macOS can refuse when the sign-in opens on
        // its own (a session expiring in the background); this puts the
        // window in front either way.
        loginWindow?.orderFrontRegardless()
    }

    private func finishLogin() {
        loginWindow?.orderOut(nil)
        loginWindow = nil
        if let account = loginAccount {
            viewModel.signedIn(account)
        } else {
            viewModel.loggedIn()
        }
        loginAccount = nil
    }

    @objc private func handleOpenLogin() {
        showLoginWindow()
    }

    // Closing the sign-in window without finishing leaves the account pending;
    // its row in the popover offers the sign-in again.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as AnyObject) === loginWindow {
            loginWindow = nil
        }
    }
}

extension Notification.Name {
    // Posted by the popover's "Sign In" button to (re)open the login window.
    static let openLogin = Notification.Name("JuicageOpenLogin")
}
