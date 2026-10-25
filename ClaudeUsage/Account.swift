import Foundation
import WebKit
import Combine
import SwiftUI
import AppKit

// One claude.ai sign-in.
//
// Separate accounts need separate cookie jars — signing into a second one in the
// shared store would just sign you out of the first. WKWebsiteDataStore gives
// isolated persistent stores keyed by UUID, but only on macOS 14+.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String

    // The first account deliberately keeps the shared default store rather than
    // moving to an isolated one: that's where an existing install's sign-in
    // already lives, and migrating it would silently sign everyone out on
    // upgrade. Same reasoning as freezing the bundle identifier through the
    // rename.
    var usesLegacyStore: Bool

    // A color to tell this account apart at a glance — "#RRGGBB", or nil for
    // none. Optional, so lists saved before it existed still decode.
    var color: String? = nil

    // The Chrome profile (its folder, e.g. "Profile 2") whose theme this
    // account wears. While set, `color` follows that theme and holds the last
    // color read from it.
    var chromeProfile: String? = nil

    var swatch: Color? { color.flatMap(Color.init(hex:)) }
}

extension Color {
    // "#RRGGBB" → a color; nil for anything else.
    nonisolated init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    // Black or white, whichever has more contrast against this color. The
    // crossover sits at a relative luminance of about 0.18, not 0.5: white
    // stops reading well on mid-tones sooner than intuition says.
    var readableText: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(c.redComponent)
                      + 0.7152 * linear(c.greenComponent)
                      + 0.0722 * linear(c.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}

final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    private let defaults = UserDefaults.standard
    private let key = "accounts"

    @Published private(set) var accounts: [Account] = []

    // Isolated cookie jars are macOS 14+. On Ventura the app stays
    // single-account rather than pretending and having two logins clobber
    // each other in one store.
    static var supportsMultipleAccounts: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([Account].self, from: data),
           !list.isEmpty {
            accounts = list
        } else {
            // First run, or upgrading from a single-account build: adopt the
            // existing sign-in as account one.
            accounts = [Account(id: UUID(), name: "Claude", usesLegacyStore: true)]
            persist()
        }
    }

    func add(name: String) {
        guard Self.supportsMultipleAccounts else { return }
        accounts.append(Account(id: UUID(), name: name, usesLegacyStore: false))
        persist()
    }

    func rename(_ account: Account, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].name = name
        persist()
    }

    func setColor(_ account: Account, to color: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[i].color != color else { return }
        accounts[i].color = color
        persist()
    }

    func linkChromeProfile(_ account: Account, to profile: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[i].chromeProfile != profile else { return }
        accounts[i].chromeProfile = profile
        persist()
        syncChromeColors()
    }

    // Gives each linked account its Chrome profile's current theme color.
    // Called where the color shows — the popover and Preferences opening —
    // so a theme changed in Chrome is there the next time you look, with
    // nothing watching Chrome's files in between.
    func syncChromeColors() {
        for account in accounts {
            guard let profile = account.chromeProfile else { continue }
            switch ChromeProfiles.theme(ofProfile: profile) {
            case .color(let hex): setColor(account, to: hex)
            case .none:           setColor(account, to: nil)
            case .unreadable:     continue      // keep the last color read
            }
        }
    }

    func remove(_ account: Account) {
        // Never drop the last one; the app has nothing to show without it.
        guard accounts.count > 1 else { return }
        accounts.removeAll { $0.id == account.id }
        persist()
        // Take the cookies with it, so "remove" actually signs out.
        if !account.usesLegacyStore, #available(macOS 14.0, *) {
            WKWebsiteDataStore.remove(forIdentifier: account.id) { _ in }
        }
    }

    // The cookie jar an account signs into.
    static func dataStore(for account: Account) -> WKWebsiteDataStore {
        if account.usesLegacyStore { return .default() }
        if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: account.id) }
        return .default()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: key)
    }
}
