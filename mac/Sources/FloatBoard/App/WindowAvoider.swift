import FloatBoardCore
import AppKit
import ApplicationServices

/// Keeps other apps' windows from extending under the bar, a bit like the Dock reserving space.
/// macOS has no public API for reserving a screen edge, so this uses the Accessibility API:
/// about once a second it shrinks any standard window whose bottom edge runs under the bar.
/// Requires the Accessibility permission (System Settings → Privacy & Security → Accessibility).
@MainActor
final class WindowAvoider {
    /// The bar's frame (Cocoa coordinates) when windows should avoid it, or nil when they shouldn't.
    private let barFrame: () -> NSRect?
    private var timer: Timer?
    private var prompted = false
    /// Windows we shrank, with where their bottom edge was before, so we can give the space back.
    private var shrunk: [(window: AXUIElement, originalBottom: CGFloat, ourBottom: CGFloat)] = []
    private var lastState = ""
    /// How far a window may tuck under the bar. Grid-snapping windows (Terminal) can't land exactly on
    /// the bar's edge; a few points under it (just the window border) looks better than a visible gap.
    private let tuck: CGFloat = 4
    /// Windows that ignore resize requests (e.g. Finder's desktop); skipped from then on.
    private var stubborn: [AXUIElement] = []

    /// Small diagnostic log: ~/Library/Logs/FloatBoard.log
    /// Set by the app so a failure to write the diagnostic log shows up in Activity (once per distinct problem).
    var store: Store?
    private var lastLogFailure = ""

    private func log(_ msg: String) {
        let url = LocalData.logFile
        let line = "\(Fmt.csvDate(Date())) \(msg)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!)
                try? h.close() // try?-ok: closing a handle after the write completed
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
            lastLogFailure = ""
        } catch {
            guard "\(error)" != lastLogFailure else { return }
            lastLogFailure = "\(error)"
            store?.activity("window-avoider", .warning, "Could not write the diagnostic log file", detail: "\(error)")
        }
    }

    private func noteState(_ s: String) {
        if s != lastState { lastState = s; log("state: \(s)") }
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "avoidWindows")
            restart()
        }
    }

    var trusted: Bool { AXIsProcessTrusted() }

    init(barFrame: @escaping () -> NSRect?) {
        self.barFrame = barFrame
        enabled = UserDefaults.standard.object(forKey: "avoidWindows") as? Bool ?? true
        restart()
    }

    /// Shows the system prompt that links to the Accessibility settings.
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        guard enabled else { restoreAll(); return }
        // Ask via the system pop-up only once ever; after that, the menu bar item is the way in.
        if !trusted && !prompted && !UserDefaults.standard.bool(forKey: "axPrompted") {
            prompted = true
            UserDefaults.standard.set(true, forKey: "axPrompted")
            requestPermission()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // Don't fight the user while they're dragging or resizing something.
        guard trusted else {
            // Probe with a real call too, in case the trust flag is stale.
            var probe = "n/a"
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                var v: CFTypeRef?
                let r = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder.processIdentifier),
                                                      kAXWindowsAttribute as CFString, &v)
                probe = "\(r.rawValue)"
            }
            noteState("NO accessibility permission (probe \(probe), bundle \(Bundle.main.bundlePath))")
            return
        }
        guard NSEvent.pressedMouseButtons == 0, let primary = NSScreen.screens.first else { return }
        guard let bar = barFrame() else {
            noteState("released (bar minimised/closed)")
            restoreAll() // bar minimised or closed: give the space back
            return
        }
        // Accessibility uses top-left-origin coordinates measured from the primary screen.
        let barTop = primary.frame.maxY - bar.maxY
        noteState("reserving, bar top at \(Int(barTop))")
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me && !app.isHidden {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2) // never hang on a frozen app
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for w in windows { fit(w, barTop: barTop, minX: bar.minX, maxX: bar.maxX, app: app.localizedName ?? "?") }
        }
    }

    private func fit(_ w: AXUIElement, barTop: CGFloat, minX: CGFloat, maxX: CGFloat, app: String) {
        if stubborn.contains(where: { CFEqual($0, w) }) { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return }
        if bool(w, kAXMinimizedAttribute as String) || bool(w, "AXFullScreen") { return }
        if let sub = string(w, kAXSubroleAttribute as String), sub != kAXStandardWindowSubrole as String { return }
        guard let pos = point(w), let size = size(w) else { return }
        guard pos.x < maxX, pos.x + size.width > minX else { return } // not horizontally under the bar
        let bottom = pos.y + size.height
        // Only windows that start above the bar, run under it, and would still be a usable size.
        guard bottom > barTop + tuck, pos.y < barTop - 150 else { return }
        // Some windows snap to a grid (Terminal resizes in whole text lines) and ignore small
        // changes, so try a few slightly smaller heights. Windows that never budge (Finder's desktop)
        // are remembered and skipped, so we don't retry them every second.
        var fitted = false
        var landed = barTop
        for extra in [0.0, -3.0, 8.0, 16.0, 24.0, 36.0] as [CGFloat] {
            var target = CGSize(width: size.width, height: barTop - pos.y - extra)
            guard let v = AXValueCreate(.cgSize, &target) else { break }
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
            if let a = self.size(w), let p2 = point(w), p2.y + a.height <= barTop + tuck { fitted = true; landed = p2.y + a.height; break }
        }
        if !fitted {
            stubborn.append(w)
            log("\(app) window won't resize; skipping it")
            return
        }
        do {
            log("shrank \(app) window: bottom \(Int(bottom)) → \(Int(landed))")
            if let i = shrunk.firstIndex(where: { CFEqual($0.window, w) }) {
                shrunk[i].ourBottom = landed
            } else {
                shrunk.append((w, bottom, landed))
            }
        }
    }

    /// Grow windows we shrank back to their original bottom edge, unless the user has resized
    /// or moved them since (then their bottom edge is no longer where we left it).
    private func restoreAll() {
        guard !shrunk.isEmpty else { return }
        if trusted {
            for s in shrunk {
                guard let pos = point(s.window), let size = size(s.window),
                      abs(pos.y + size.height - s.ourBottom) < 2 else { continue }
                var newSize = CGSize(width: size.width, height: s.originalBottom - pos.y)
                if let v = AXValueCreate(.cgSize, &newSize) {
                    let r = AXUIElementSetAttributeValue(s.window, kAXSizeAttribute as CFString, v)
                    log("restored window: bottom → \(Int(s.originalBottom)) (\(r == .success ? "ok" : "failed"))")
                }
            }
        }
        shrunk.removeAll()
    }

    // MARK: AX helpers

    private func attr(_ w: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, name as CFString, &v) == .success ? v : nil
    }
    private func bool(_ w: AXUIElement, _ name: String) -> Bool { (attr(w, name) as? Bool) ?? false }
    private func string(_ w: AXUIElement, _ name: String) -> String? { attr(w, name) as? String }
    private func point(_ w: AXUIElement) -> CGPoint? {
        guard let v = attr(w, kAXPositionAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    private func size(_ w: AXUIElement) -> CGSize? {
        guard let v = attr(w, kAXSizeAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
