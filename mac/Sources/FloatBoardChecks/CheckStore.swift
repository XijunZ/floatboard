import FloatBoardCore
import Foundation

/// The shared check board: a fresh database file `name` under `root`, with `modules` turned on. A setup failure fails a
/// check (named after `name`) and returns nil. The per-area helpers (jotsStore, decisionsStore, …) are this with their modules.
@MainActor func checkStore(_ root: URL, _ name: String, modules: [Module] = []) -> Store? {
    do {
        let s = Store(db: try DB(url: root.appendingPathComponent(name)))
        for m in modules { s.setModule(m, on: true) }
        return s
    } catch { check(false, "check board setup \(name): \(error)"); return nil }
}

/// A new scratch folder for one group of checks (removed by the caller's `defer`).
func checkFolder(_ prefix: String) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks after it
    return root
}
