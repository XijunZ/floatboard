import Foundation

/// The assistant's areas, each switched on or off in Settings › Areas (features: ground rules, §9 Modules).
public enum Module: String, CaseIterable, Codable {
    case jots, circle, decisions, resolutions
    public var title: String {
        switch self { case .jots: "Jots"; case .circle: "Circle"; case .decisions: "Decisions"; case .resolutions: "Resolutions" }
    }
    /// The module this one needs switched on: Decisions reads jots.
    public var requires: Module? { self == .decisions ? .jots : nil }
    /// One line for Settings.
    public var blurb: String {
        switch self {
        case .jots: "One place for your notes, meeting notes and task notes."
        case .circle: "Who matters, when you last talked, and who is due."
        case .decisions: "Records the decisions in your jots so you can review them."
        case .resolutions: "Five-year, yearly and quarterly goals, with the work that serves them."
        }
    }
}

/// Hooks run when a module is switched, so each area can start or stop its background jobs. Data is never deleted.
@MainActor public enum ModuleHooks {
    private static var hooks: [Module: [(Bool) -> Void]] = [:]
    /// `f(true)` after the module is switched on, `f(false)` after it is switched off.
    public static func onChange(_ m: Module, _ f: @escaping (Bool) -> Void) { hooks[m, default: []].append(f) }
    static func fire(_ m: Module, _ on: Bool) { hooks[m]?.forEach { $0(on) } }
}

extension Store {
    /// meta key holding the modules that are on (a JSON list). No row = none on (a new board); the upgrade to 12 writes all four.
    static let modulesKey = "modules"

    static func readModules(_ db: DB) throws -> Set<Module> {
        guard let raw = try db.query("SELECT value FROM meta WHERE key=?", [modulesKey], { DB.text($0, 0) }).first else { return [] }
        let names = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String] ?? [] // try?-ok: unreadable = none on; the row is rewritten at the next switch
        return Set(names.compactMap(Module.init(rawValue:)))
    }

    public func isOn(_ m: Module) -> Bool { modules.contains(m) }

    /// Switches a module. Returns why it was refused, or nil once saved (hooks then run).
    @discardableResult
    public func setModule(_ m: Module, on: Bool) -> String? {
        if let refusal = Self.moduleRefusal(m, on: on, current: modules) { return refusal }
        guard modules.contains(m) != on else { return nil }
        var next = modules
        if on { next.insert(m) } else { next.remove(m) }
        let names = Module.allCases.filter(next.contains).map(\.rawValue)
        perform {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self)
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.modulesKey, json])
        }
        guard modules.contains(m) == on else { return "Could not save the change; see Activity." }
        activity("settings", .info, "\(m.title) switched \(on ? "on" : "off")")
        ModuleHooks.fire(m, on)
        return nil
    }

    /// The rule: a module can't go on without the one it needs, and one that another needs can't go off first.
    public static func moduleRefusal(_ m: Module, on: Bool, current: Set<Module>) -> String? {
        if on, let need = m.requires, !current.contains(need) { return "\(m.title) needs \(need.title): switch \(need.title) on first." }
        if !on, let user = Module.allCases.first(where: { $0.requires == m && current.contains($0) }) {
            return "\(user.title) needs \(m.title): switch \(user.title) off first."
        }
        return nil
    }
}
