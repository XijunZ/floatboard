import FloatBoardCore
import Foundation

public enum CredentialsError: Error, CustomStringConvertible {
    case unreadable(String), unwritable(String)
    public var description: String {
        switch self {
        case .unreadable(let m): return "The credentials file could not be read: \(m)"
        case .unwritable(let m): return "The credentials file could not be written: \(m)"
        }
    }
}

/// Where connection secrets (engine address and key, Google tokens) are kept: a private JSON file (owner
/// read/write only) in FloatBoard's Application Support folder. "No file yet" is an empty set; a file that
/// exists but cannot be read is an error, so a damaged file is never silently overwritten with an empty one.
public enum Credentials {
    /// FLOATBOARD_CREDS lets self-tests use a throwaway file instead of the real credentials. See `LocalData`.
    public static var url: URL { LocalData.credentials }

    nonisolated(unsafe) private static var cache: [String: String]?

    /// Checks only: forget the in-memory copy so the next read goes to the file (after a check changes FLOATBOARD_CREDS).
    public static func resetCacheForTesting() { cache = nil }

    /// Runs a credentials operation; any failure is written to the Activity log (never the secret, only the error) and rethrown.
    @MainActor
    public static func logging<T>(_ action: String, store: Store, _ work: () throws -> T) throws -> T {
        do { return try work() } catch {
            store.activity("credentials", .error, "Could not \(action)", detail: "\(error)")
            throw error
        }
    }

    static var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func all() throws -> [String: String] {
        if let cache { return cache }
        guard fileExists else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw CredentialsError.unreadable("not a list of text values")
            }
            cache = dict
            return dict
        } catch let e as CredentialsError { throw e } catch { throw CredentialsError.unreadable("\(error)") }
    }

    public static func get(_ key: String) throws -> String? { try all()[key] }

    public static func set(_ value: String, _ key: String) throws { var d = try all(); d[key] = value; try save(d) }

    public static func delete(_ key: String) throws { var d = try all(); d[key] = nil; try save(d) }

    public static func save(_ dict: [String: String]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            cache = dict
        } catch { throw CredentialsError.unwritable("\(error)") }
    }
}
