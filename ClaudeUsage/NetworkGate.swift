import Foundation

// When a check of the usage may run, given what macOS says about the
// network. A check asked for while the Mac is offline, as it often is for a
// moment after waking, is owed and runs once the network is back. A check
// that fails for want of a network, as it can before macOS has noticed the
// network go, runs again at once if macOS reported a change while it ran,
// and otherwise when macOS next does. The Mac counts as offline until macOS
// first says.
struct NetworkGate {
    private(set) var online = false
    /// A check was asked for and has not run.
    private(set) var owed = false
    private var changes = 0
    private var changesAtCheck = 0

    /// A check is asked for. Returns whether to start it now.
    mutating func checkRequested() -> Bool {
        guard online else {
            owed = true
            return false
        }
        owed = false
        changesAtCheck = changes
        return true
    }

    /// macOS reports whether the network is there. Returns whether to start
    /// an owed check now.
    mutating func networkChanged(online: Bool) -> Bool {
        self.online = online
        changes += 1
        return online && owed && checkRequested()
    }

    /// A check failed for want of a network. Returns whether to start it
    /// again now.
    mutating func checkFailedForNetwork() -> Bool {
        if online, changes != changesAtCheck {
            return checkRequested()
        }
        owed = true
        return false
    }
}
