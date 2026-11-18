import Foundation

/// The engine inside the Mac (Mac only mode) runs `mac/Resources/engine.js`, a file git ignores. Checks against an old build
/// once hid a real failure, so every run builds it first from `engine/` (esbuild, about a tenth of a second) and stops loudly
/// when it can't: never a silent skip, never a stale engine. `FLOATBOARD_NODE` names another Node (also used to test this).
func rebuildEngineBundle() {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let engine = repo.appendingPathComponent("engine"), out = repo.appendingPathComponent("mac/Resources/engine.js")
    let fail = { (why: String) -> Never in
        print("CHECKS FAILED: mac/Resources/engine.js could not be rebuilt (\(why)). Run `npm ci && npm run build:mac` in engine/, then the checks again.")
        exit(1)
    }
    guard FileManager.default.fileExists(atPath: engine.appendingPathComponent("node_modules/esbuild").path) else { fail("engine/node_modules is missing") }
    let before = (try? FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date) ?? nil // try?-ok: no file yet = nothing to compare
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [ProcessInfo.processInfo.environment["FLOATBOARD_NODE"] ?? "node", "local/build.mjs"]
    p.currentDirectoryURL = engine
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { fail("Node could not be started: \(error)") }
    p.waitUntilExit()
    let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0 else { fail("the build said: \(said.suffix(400))") }
    let after = (try? FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date) ?? nil // try?-ok: nil fails below
    guard let after, after > (before ?? .distantPast) else { fail("the build ran but engine.js was not written") }
    print("engine.js rebuilt from engine/ for the Mac engine checks")
}
