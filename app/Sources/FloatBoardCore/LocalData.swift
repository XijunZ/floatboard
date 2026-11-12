import Foundation

/// Every place on this Mac where FloatBoard keeps data. Nothing here is ever committed to the repository; see
/// docs/data-model.md ("Your Mac"). Each location can be redirected with an environment variable so checks and
/// development runs never touch the real files.
public enum LocalData {
    /// Overrides the board database file.
    public static let databaseEnv = "FLOATBOARD_DB"
    /// Overrides the private credentials file (connector keys, optional Google Calendar sign-in).
    public static let credentialsEnv = "FLOATBOARD_CREDS"
    /// Overrides the backups folder.
    public static let backupsEnv = "FLOATBOARD_BACKUPS"

    /// `~/Library/Application Support/FloatBoard/`: the folder that holds the database, credentials and backups.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatBoard", isDirectory: true)
    }

    /// The board database (the single source of truth): `FLOATBOARD_DB`, else `<support>/board.sqlite`.
    public static var database: URL {
        if let p = env(databaseEnv) { return URL(fileURLWithPath: p) }
        return supportDirectory.appendingPathComponent("board.sqlite")
    }

    /// The private credentials file (owner read/write only): `FLOATBOARD_CREDS`, else `<support>/google-credentials.json`.
    public static var credentials: URL {
        if let p = env(credentialsEnv) { return URL(fileURLWithPath: p) }
        return supportDirectory.appendingPathComponent("google-credentials.json")
    }

    /// The backups folder: `FLOATBOARD_BACKUPS`; else nil when `FLOATBOARD_DB` points at a scratch database (so a test
    /// never backs up into the real folder); else `<support>/Backups`.
    public static var backups: URL? {
        if let p = env(backupsEnv) { return URL(fileURLWithPath: p, isDirectory: true) }
        if env(databaseEnv) != nil { return nil }
        return supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Engine data archived to this Mac ("Archive old data to this Mac"): `archives/` beside the backups folder (same
    /// base folder, so it follows `FLOATBOARD_BACKUPS`); nil when there is no backups folder (a scratch database).
    public static var archives: URL? {
        backups?.deletingLastPathComponent().appendingPathComponent("archives", isDirectory: true)
    }

    /// The small diagnostic log written by the window avoider: `~/Library/Logs/FloatBoard.log` (no override).
    public static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FloatBoard.log")
    }

    /// True when the database has been redirected (a check or development run, not the real board).
    public static var isScratchDatabase: Bool { env(databaseEnv) != nil }

    private static func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }
}
