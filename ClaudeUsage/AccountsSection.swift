import SwiftUI
import AppKit

// The Accounts block in Preferences: add, rename and remove claude.ai sign-ins.
//
// Adding an account doesn't ask for credentials — it creates an empty cookie jar
// and lets the normal sign-in window fill it, the same path a first-time user
// takes. Juicage never sees a password.
struct AccountsSection: View {
    @ObservedObject private var store = AccountStore.shared
    @EnvironmentObject private var viewModel: UsageViewModel

    // Removal signs the account out and deletes its cookies, so it asks first.
    @State private var pendingRemoval: Account?

    // Read when the section appears; empty without Chrome, which hides the
    // picker.
    @State private var chromeProfiles: [ChromeProfiles.Profile] = []

    var body: some View {
        Section {
            ForEach(store.accounts) { account in
                AccountRow(
                    account: account,
                    chromeProfiles: chromeProfiles,
                    needsSignIn: viewModel.pendingLogins.contains { $0.id == account.id },
                    canRemove: store.accounts.count > 1,
                    onSignIn: { signIn(account) },
                    onRemove: { pendingRemoval = account }
                )
            }

            if AccountStore.supportsMultipleAccounts {
                Button("Add Sign-In…", action: addAccount)
            } else {
                // Isolated cookie jars are macOS 14+. Rather than pretend, say so:
                // two logins sharing one store would sign each other out on every
                // refresh, which looks like a bug rather than a limitation.
                Text("Signing in to more than one account needs macOS 14 or later.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("Accounts")
        } footer: {
            if store.accounts.count > 1 {
                Text("Each sign-in keeps its own session. Limits are shown per account in the popover.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { chromeProfiles = ChromeProfiles.profiles() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this account")?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove and Sign Out", role: .destructive) {
                if let account = pendingRemoval { store.remove(account) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This signs the account out on this Mac. Recorded history is kept.")
        }
    }

    private func addAccount() {
        // A placeholder name rather than a prompt: the row is editable in place,
        // and one fewer dialog between wanting an account and having one.
        let name = "Account \(store.accounts.count + 1)"
        store.add(name: name)
        // The new provider will report that it needs a sign-in on its own, but
        // opening the window now makes the button feel like it did something.
        if let account = store.accounts.last { signIn(account) }
    }

    private func signIn(_ account: Account) {
        (NSApp.delegate as? AppDelegate)?.showLoginWindow(for: account)
    }
}

// One account: its color, an editable name, its sign-in state, a way to
// remove it, and the Chrome profile whose theme color it can follow.
private struct AccountRow: View {
    let account: Account
    let chromeProfiles: [ChromeProfiles.Profile]
    let needsSignIn: Bool
    let canRemove: Bool
    let onSignIn: () -> Void
    let onRemove: () -> Void

    // Edited locally and committed on submit or focus loss. Writing straight
    // through on each keystroke would republish the account list — and rebuild
    // every provider — once per character typed.
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if !chromeProfiles.isEmpty {
                chromePicker
            }
        }
    }

    // A linked profile that Chrome no longer lists still shows, so the
    // picker never claims an account is unlinked when it isn't.
    private var chromeChoices: [ChromeProfiles.Profile] {
        guard let linked = account.chromeProfile,
              !chromeProfiles.contains(where: { $0.id == linked }) else { return chromeProfiles }
        return chromeProfiles + [ChromeProfiles.Profile(id: linked, name: "\(linked) (missing)", email: nil)]
    }

    private var chromePicker: some View {
        Picker("Color from Chrome", selection: Binding(
            get: { account.chromeProfile },
            set: { AccountStore.shared.linkChromeProfile(account, to: $0) })) {
            Text("None").tag(String?.none)
            ForEach(chromeChoices) { profile in
                Text(profile.label).tag(Optional(profile.id))
            }
        }
        .font(.caption)
        .controlSize(.small)
        .help("Follow this Chrome profile's theme color")
    }

    private var row: some View {
        HStack(spacing: 8) {
            // An account with no color shows a plain heading; the well shows
            // gray until one is picked. Following Chrome, the theme sets it.
            ColorPicker("Color", selection: Binding(
                get: { account.swatch ?? .gray },
                set: { AccountStore.shared.setColor(account, to: $0.hex) }),
                supportsOpacity: false)
                .labelsHidden()
                .disabled(account.chromeProfile != nil)
                .help(account.chromeProfile == nil ? "This account's color in the popover"
                                                   : "Set by the Chrome profile's theme")
                .contextMenu {
                    Button("No Color") { AccountStore.shared.setColor(account, to: nil) }
                        .disabled(account.color == nil || account.chromeProfile != nil)
                }

            TextField("Name", text: $draft)
                .labelsHidden()          // inside a Form the label otherwise renders as a column: "Name  Claude"
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { isFocused in if !isFocused { commit() } }
                .onAppear { draft = account.name }
                .onChange(of: account.name) { draft = $0 }

            Spacer(minLength: 8)

            if needsSignIn {
                Button("Sign In", action: onSignIn)
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Text("Signed in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            // The last account can't go: with none, the app has nothing to show.
            .help(canRemove ? "Remove this sign-in" : "The last account can't be removed")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != account.name else {
            draft = account.name          // reject blank names rather than saving one
            return
        }
        AccountStore.shared.rename(account, to: trimmed)
    }
}
