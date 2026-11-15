import AppKit
import FloatBoardConnectors
import FloatBoardCore
import Foundation
import UserNotifications

/// Updates (Settings › Mode › Updates, the menu bar menu, Help › Check for Updates…): when FloatBoard starts and once
/// a day, it asks GitHub whether `main` has changes this build doesn't. "Update now" (or automatically at launch, if
/// switched on) runs in the source folder this app was built from: git pull, then the online engine (database changes
/// first, then deploy) if this Mac deploys one, then rebuild, reinstall and reopen. It stops on any problem, keeps the
/// running version, and says why; everything is logged to ~/Library/Logs/FloatBoard-update.log.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    enum State: Equatable { case idle, checking, upToDate, available(UpdateCheck.Available), updating(String), failed(String), unknown(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    weak var store: Store?
    private var timer: Timer?
    static let autoKey = "updates.auto"
    static let notifiedKey = "updates.notified"

    var built: String { Bundle.main.object(forInfoDictionaryKey: "FloatBoardCommit") as? String ?? "" }
    var sourceDir: String { Bundle.main.object(forInfoDictionaryKey: "FloatBoardSourceDir") as? String ?? "" }
    var repo: String { Bundle.main.object(forInfoDictionaryKey: "FloatBoardRepo") as? String ?? "" }
    var autoInstall: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey); objectWillChange.send() }
    }
    static var logURL: URL { LocalData.logFile.deletingLastPathComponent().appendingPathComponent("FloatBoard-update.log") }

    func start(store: Store) {
        self.store = store
        guard !repo.isEmpty, !LocalData.isScratchDatabase else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.scheduleCheck(launch: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.scheduleCheck(launch: false) }
        }
    }

    private func scheduleCheck(launch: Bool) {
        _Concurrency.Task { @MainActor in
            await self.check(launch: launch)
        }
    }

    /// Asks GitHub (no account needed). Offline or rate-limited: quietly tries again next time.
    func check(launch: Bool = false) async {
        guard !repo.isEmpty else { state = .unknown("this build doesn't know which GitHub repository it came from"); return }
        if case .updating = state { return }
        state = .checking
        do {
            let head = try await Self.json("https://api.github.com/repos/\(repo)/commits/main")?["sha"] as? String ?? ""
            let compare = built.isEmpty || head == built ? nil : try? await Self.json("https://api.github.com/repos/\(repo)/compare/\(built)...\(head)") // try?-ok: a 404 means this build isn't on GitHub, handled by decide
            lastChecked = Date()
            switch UpdateCheck.decide(built: built, compare: compare, head: head) {
            case .upToDate: state = .upToDate
            case .unknown(let why): state = .unknown(why)
            case .available(let a):
                state = .available(a)
                if UserDefaults.standard.string(forKey: Self.notifiedKey) != a.head {
                    UserDefaults.standard.set(a.head, forKey: Self.notifiedKey)
                    store?.activity("updates", .info, "Update available: \(a.count) change\(a.count == 1 ? "" : "s")", detail: a.messages.joined(separator: "\n"))
                    notify(a)
                }
                if launch && autoInstall { update() }
            }
        } catch {
            state = .idle // offline: nothing to say; the next check tries again
        }
    }

    private static func json(_ url: String) async throws -> [String: Any]? {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FloatBoard", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 422 { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func notify(_ a: UpdateCheck.Available) {
        let c = UNMutableNotificationContent()
        c.title = "FloatBoard update available"
        c.body = "\(a.count) change\(a.count == 1 ? "" : "s"): " + (a.messages.first ?? "") + ". Install it from the menu bar menu."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "floatboard-update-\(a.head)", content: c, trigger: nil)) { _ in }
    }

    /// Runs the update in the source folder. Stops at the first problem; the running app stays until the new one is
    /// installed, then reopens.
    func update() {
        if case .updating = state { return }
        let dir = sourceDir
        guard !dir.isEmpty, FileManager.default.fileExists(atPath: dir + "/.git") else {
            state = .failed("the source folder this app was built from isn't on this Mac (\(dir.isEmpty ? "unknown" : dir))")
            return
        }
        let engine = FileManager.default.fileExists(atPath: dir + "/engine/wrangler.local.toml")
        // Each step is logged; `set -e` stops at the first failure. The login shell gives the same tools as Terminal.
        let script = """
            set -e
            cd \(Self.quote(dir))
            echo "== $(date) updating from $(git rev-parse --short HEAD)"
            if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "STOP: the source folder has changes that aren't committed"; exit 3; fi
            git fetch --quiet origin main
            if [ -n "$(git log --oneline origin/main..HEAD)" ]; then echo "STOP: the source folder has commits that aren't on GitHub"; exit 4; fi
            git merge --ff-only --quiet origin/main
            \(engine ? "cd engine && npm ci --silent && npm run --silent update && cd .." : "echo 'no online engine deployed from this Mac'")
            cd mac && ./scripts/build-app.sh
            echo "== done $(git rev-parse --short HEAD)"
            """
        state = .updating("Updating… (1–2 minutes; FloatBoard reopens when done)")
        store?.activity("updates", .info, "Updating FloatBoard", detail: engine ? "code, online engine and app" : "code and app")
        let log = Self.logURL
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", script]
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try? FileHandle(forWritingTo: log) // try?-ok: without a log file the update still runs; the result is reported
            h?.seekToEndOfFile()
            p.standardOutput = h; p.standardError = h
            var code: Int32 = -1
            do { try p.run(); p.waitUntilExit(); code = p.terminationStatus } catch { code = -1 }
            try? h?.close() // try?-ok: closing the log
            let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").suffix(3).joined(separator: " · ") ?? "" // try?-ok: only for the message
            await MainActor.run { Updater.shared.finished(code: code, tail: tail) }
        }
    }

    private func finished(code: Int32, tail: String) {
        guard code == 0 else {
            let why = tail.contains("STOP:") ? String(tail[tail.range(of: "STOP:")!.upperBound...]).trimmingCharacters(in: .whitespaces)
                : "the update stopped (details in ~/Library/Logs/FloatBoard-update.log)"
            state = .failed(why)
            store?.activity("updates", .warning, "Update didn't finish; this version keeps running", detail: tail)
            return
        }
        store?.activity("updates", .info, "Updated; reopening FloatBoard")
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/FloatBoard.app"), configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
