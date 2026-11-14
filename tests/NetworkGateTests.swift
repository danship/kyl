import Foundation

func networkGateTests() {
    // Until macOS first says, the Mac counts as offline, and a check waits.
    var gate = NetworkGate()
    expect(!gate.checkRequested(), "no check before macOS says the network is there")
    expect(gate.owed, "the check is owed")
    expect(gate.networkChanged(online: true), "it runs when the network comes")
    expect(!gate.owed, "and is no longer owed")
    expect(!gate.networkChanged(online: true), "a later report starts nothing when nothing is owed")

    // Online, a check runs at once.
    expect(gate.checkRequested(), "online, a check runs at once")

    // Going offline holds checks; coming back runs one.
    expect(!gate.networkChanged(online: false), "going offline starts nothing")
    expect(!gate.checkRequested(), "a check asked for offline waits")
    expect(!gate.networkChanged(online: false), "another offline report starts nothing")
    expect(gate.networkChanged(online: true), "the owed check runs when the network is back")

    // A check that fails for want of a network while macOS still says
    // online waits for macOS to report a change.
    var waking = NetworkGate()
    _ = waking.networkChanged(online: true)
    expect(waking.checkRequested(), "a check starts")
    expect(!waking.checkFailedForNetwork(), "it failed with no change reported: wait")
    expect(waking.owed, "the check is owed")
    expect(waking.networkChanged(online: true), "the next report runs it")

    // If macOS reported a change while the check ran, it runs again at once.
    var changed = NetworkGate()
    _ = changed.networkChanged(online: true)
    expect(changed.checkRequested(), "a check starts")
    _ = changed.networkChanged(online: true)
    expect(changed.checkFailedForNetwork(), "the network changed while it ran: again now")
    expect(!changed.owed, "nothing is owed once it runs")

    // But not if macOS has since said the network is gone.
    var gone = NetworkGate()
    _ = gone.networkChanged(online: true)
    expect(gone.checkRequested(), "a check starts")
    _ = gone.networkChanged(online: false)
    expect(!gone.checkFailedForNetwork(), "offline now: wait")
    expect(gone.networkChanged(online: true), "and run when it comes back")
}
