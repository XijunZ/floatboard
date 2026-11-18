import Foundation
import FloatBoardConnectors

/// "Update now" and the app build always have the engine's packages (Claude review of 3f4369c): the update script runs
/// `npm ci` for every user (not only those who deploy an online engine), and the build's engine step installs the packages
/// itself when they are missing or older than package-lock.json, stopping only when npm itself is missing.
func updatePathChecks() {
    // The update script.
    for deploys in [false, true] {
        let s = UpdateCheck.updateScript(dir: "/src/fb", deploysEngine: deploys)
        let ci = s.range(of: "(cd engine && npm ci --silent)"), build = s.range(of: "./scripts/build-app.sh")
        check(ci != nil && build != nil && ci!.lowerBound < build!.lowerBound && s.contains("cd '/src/fb'")
              && s.contains("npm run --silent update") == deploys, "update_script_runs_npm_ci_before_the_build_\(deploys ? "with" : "without")_an_online_engine")
    }

    // The build's engine step (scripts/prepare-engine.sh), run with stand-in node and npm on a scratch engine folder.
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-prepare-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch cleanup
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/prepare-engine.sh")
    let engine = root.appendingPathComponent("engine"), bin = root.appendingPathComponent("bin"), out = root.appendingPathComponent("engine.js")
    let log = root.appendingPathComponent("calls.log")
    do {
        try fm.createDirectory(at: engine.appendingPathComponent("local"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        // npm ci: records the call and writes node_modules/.package-lock.json (as the real one does).
        try """
            #!/bin/bash
            echo "npm $*" >> "\(log.path)"
            mkdir -p node_modules && echo '{}' > node_modules/.package-lock.json
            """.write(to: bin.appendingPathComponent("npm"), atomically: true, encoding: .utf8)
        try """
            #!/bin/bash
            echo "node $*" >> "\(log.path)"
            echo 'built' > "$FLOATBOARD_ENGINE_OUT"
            """.write(to: bin.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        for t in ["npm", "node"] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(t).path) }
        try "{}".write(to: engine.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
    } catch { check(false, "prepare-engine setup: \(error)"); return }

    func run(path: String) -> (code: Int32, said: String, calls: [String]) {
        try? fm.removeItem(at: log) // try?-ok: no log yet is fine
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": path, "FLOATBOARD_ENGINE_DIR": engine.path, "FLOATBOARD_ENGINE_OUT": out.path, "HOME": root.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)", []) }
        p.waitUntilExit()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) // try?-ok: no calls = empty
        return (p.terminationStatus, said, calls)
    }
    let path = bin.path + ":/usr/bin:/bin"
    let first = run(path: path)   // no node_modules yet
    check(first.code == 0 && first.calls == ["npm ci --silent", "node local/build.mjs"] && fm.fileExists(atPath: out.path),
          "engine_build_installs_packages_when_node_modules_is_missing")
    let again = run(path: path)   // installed and up to date: no install
    check(again.code == 0 && again.calls == ["node local/build.mjs"], "engine_build_skips_npm_ci_when_packages_are_current")
    // package-lock.json changed after the last install: install again.
    let later = Date().addingTimeInterval(60)
    try? fm.setAttributes([.modificationDate: later], ofItemAtPath: engine.appendingPathComponent("package-lock.json").path) // try?-ok: the check below fails if not set
    let newer = run(path: path)
    check(newer.code == 0 && newer.calls == ["npm ci --silent", "node local/build.mjs"], "engine_build_reinstalls_when_package_lock_is_newer")
    // No npm at all: stop with a clear message, nothing built.
    try? fm.removeItem(at: out) // try?-ok: the check below fails if it is still there
    try? fm.removeItem(at: bin.appendingPathComponent("npm")) // try?-ok: the check below fails if npm is still found
    let noNpm = run(path: path)
    check(noNpm.code != 0 && noNpm.said.contains("npm") && noNpm.said.contains("Node.js") && !fm.fileExists(atPath: out.path),
          "engine_build_stops_clearly_without_npm")
}

/// Round 13 (A1, A2): installing never leaves no app (copy beside, then swap), and says where it installed so "Update now"
/// reopens that copy. Checks run the install step on scratch folders only, never touching an installed app or a running one.
func installStepChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-install-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch cleanup
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/install-app.sh")
    let dest = root.appendingPathComponent("Apps"), new = root.appendingPathComponent("build/FloatBoard.app")
    do {
        try fm.createDirectory(at: dest.appendingPathComponent("FloatBoard.app/Contents"), withIntermediateDirectories: true)
        try "old".write(to: dest.appendingPathComponent("FloatBoard.app/Contents/version"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: new.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "new".write(to: new.appendingPathComponent("Contents/version"), atomically: true, encoding: .utf8)
    } catch { check(false, "install setup: \(error)"); return }
    func run(_ app: URL) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, app.path]
        // Scratch destination: the script then never stops or opens any app.
        p.environment = ["PATH": "/usr/bin:/bin", "FLOATBOARD_INSTALL_DEST": dest.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    let version = { (try? String(contentsOf: dest.appendingPathComponent("FloatBoard.app/Contents/version"), encoding: .utf8)) ?? "none" } // try?-ok: "none" fails the check
    let bad = run(root.appendingPathComponent("build/Missing.app"))
    check(bad.0 != 0 && version() == "old" && !fm.fileExists(atPath: dest.appendingPathComponent(".FloatBoard.app.new").path),
          "a_failed_install_keeps_the_old_app")
    let ok = run(new)
    check(ok.0 == 0 && version() == "new" && ok.1.contains("INSTALLED_AT=\(dest.path)/FloatBoard.app")
          && UpdateCheck.installedApp(fromLog: ok.1) == "\(dest.path)/FloatBoard.app"
          && !fm.fileExists(atPath: dest.appendingPathComponent(".FloatBoard.app.old").path), "install_swaps_in_the_new_app_and_says_where")
    check(UpdateCheck.installedApp(fromLog: "no line") == nil && UpdateCheck.updateScript(dir: "/x", deploysEngine: false).contains("FLOATBOARD_FROM_UPDATER=1 ./scripts/build-app.sh"),
          "update_now_tells_the_build_it_runs_from_the_app")
    let buildApp = (try? String(contentsOf: script.deletingLastPathComponent().appendingPathComponent("build-app.sh"), encoding: .utf8)) ?? "" // try?-ok: empty fails
    check(buildApp.contains("./scripts/install-app.sh") && !buildApp.contains("rm -rf \"$DEST/FloatBoard.app\""), "build_app_installs_through_the_safe_step")
    // Round 14 (8): an install that stopped between its two moves (the app moved aside, the new one not yet in) is put back
    // first, before any leftovers are cleared, even when this install then fails.
    do {
        try fm.moveItem(at: dest.appendingPathComponent("FloatBoard.app"), to: dest.appendingPathComponent(".FloatBoard.app.old"))
    } catch { check(false, "crash setup: \(error)"); return }
    let again = run(root.appendingPathComponent("build/Missing.app"))
    check(again.0 != 0 && version() == "new" && !fm.fileExists(atPath: dest.appendingPathComponent(".FloatBoard.app.old").path),
          "an_install_stopped_between_its_moves_is_put_back_first")
}
