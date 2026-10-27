import Foundation

// Codex, via the Codex CLI's own sign-in.
//
// The CLI ships an app server (`codex app-server`, JSON-RPC over stdio) that
// answers `account/rateLimits/read` with the same shape of thing claude.ai
// reports: a percentage used, when it resets, and how long the window is. The
// credentials never leave the CLI — this asks it for numbers and nothing else.
//
// One short-lived server per fetch rather than a parked one: starting it costs
// about a second every few minutes, and a parked process would be one more
// thing to recover after sleep.
final class CodexProvider: UsageProvider {
    static let providerID = "codex"

    let id = CodexProvider.providerID
    let displayName = "Codex"

    var onUsage: (([WorkspaceUsage]) -> Void)?
    var onNeedsLogin: (() -> Void)?
    var onError: ((String) -> Void)?

    // Where the CLI lives. The ChatGPT app carries one; Homebrew and npm put
    // theirs on the path, which a menu bar app launched by Finder doesn't see.
    static var binary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binary != nil }

    private let queue = DispatchQueue(label: "codex-usage", qos: .utility)
    private var inFlight = false

    func start() {
        fetch()
    }

    func fetch() {
        guard let binary = Self.binary else { return }
        queue.async { [weak self] in
            guard let self, !self.inFlight else { return }
            self.inFlight = true
            defer { self.inFlight = false }
            switch Self.readRateLimits(binary: binary) {
            case .success(let data):
                let list = Self.parse(data, providerName: self.displayName)
                DispatchQueue.main.async { self.onUsage?(list) }
            case .failure(let error):
                // The card stays, carrying the reason, so a signed-out CLI
                // reads as "sign in" rather than as a Codex that vanished.
                var ws = WorkspaceUsage()
                ws.providerID = self.id
                ws.providerName = self.displayName
                ws.error = error.message
                DispatchQueue.main.async { self.onUsage?([ws]) }
            }
        }
    }

    // MARK: - Talking to the app server

    struct Failure: Error { let message: String }

    // Runs the server, asks once, and stops it. Returns the raw `result` of
    // the rate-limits reply.
    private static func readRateLimits(binary: String) -> Result<[String: Any], Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch {
            return .failure(Failure(message: "Couldn't start the Codex CLI"))
        }
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write("\n".data(using: .utf8)!)
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "kyl", "title": "KYL",
                                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0"]]])
        send(["jsonrpc": "2.0", "method": "initialized"])
        send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read",
              "params": ["excludeResetCreditDetails": true]])

        // Read line by line until the reply to id 2 arrives, or 20 seconds pass.
        let deadline = Date().addingTimeInterval(20)
        var buffer = Data()
        let handle = output.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }                        // server exited
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? Int) == 2 else { continue }
                if let result = object["result"] as? [String: Any] { return .success(result) }
                let error = (object["error"] as? [String: Any])?["message"] as? String
                return .failure(Failure(message: Self.readable(error)))
            }
        }
        return .failure(Failure(message: "No answer from the Codex CLI"))
    }

    // The CLI's errors are written for its own terminal; the card needs the
    // one sentence a person can act on.
    private static func readable(_ error: String?) -> String {
        guard let error else { return "Codex didn't report its limits" }
        let lower = error.lowercased()
        if lower.contains("not logged in") || lower.contains("unauthorized")
            || lower.contains("auth") || lower.contains("login") {
            return "Not signed in — run `codex login`"
        }
        return error
    }

    // MARK: - Reading the reply

    // One card per metered limit the account has (today that is one, "codex").
    // A window shorter than a day is the session; anything longer is the week.
    static func parse(_ result: [String: Any], providerName: String, now: Date = Date()) -> [WorkspaceUsage] {
        var snapshots: [(String, [String: Any])] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
            snapshots = byID.sorted { $0.key < $1.key }
        } else if let single = result["rateLimits"] as? [String: Any] {
            snapshots = [((single["limitId"] as? String) ?? "codex", single)]
        }

        return snapshots.map { limitID, snapshot in
            var ws = WorkspaceUsage()
            ws.providerID = providerID
            ws.providerName = providerName
            ws.workspaceID = limitID
            // Only worth a heading once there is more than one limit to tell apart.
            ws.workspaceName = snapshots.count > 1 ? ((snapshot["limitName"] as? String) ?? limitID) : nil
            ws.lastUpdated = now

            for slot in ["primary", "secondary"] {
                guard let window = snapshot[slot] as? [String: Any],
                      let percent = window["usedPercent"] as? Int else { continue }
                let minutes = window["windowDurationMins"] as? Int
                let length = minutes.map { TimeInterval($0 * 60) }
                let reset = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let isSession = (minutes ?? 0) <= 24 * 60
                var metric = UsageMetric(key: isSession ? "codex_session" : "codex_weekly",
                                         label: isSession ? "Codex session" : "Codex week",
                                         percent: percent, resetAt: reset)
                metric.windowLength = length
                if isSession, ws.session == nil { ws.session = metric }
                else if ws.weeklyAll == nil { ws.weeklyAll = metric }
                else { ws.weeklyModels.append(metric) }
            }
            if let reached = snapshot["rateLimitReachedType"] as? String, reached != "rate_limit_reached" {
                ws.error = reached.replacingOccurrences(of: "_", with: " ")
            }
            return ws
        }
    }
}
