import FloatBoardCore
import Foundation
import Security

public enum CredentialsError: Error, CustomStringConvertible, Equatable {
    case unreadable(String), unwritable(String)
    /// The Keychain can't be used right now (the Mac is asleep or locked); trying again later works.
    case unavailable(String)
    public var description: String {
        switch self {
        case .unreadable(let m): return "The credentials file could not be read: \(m)"
        case .unwritable(let m): return "The credentials file could not be written: \(m)"
        case .unavailable(let m): return "The Keychain isn't available right now (the Mac is asleep or locked): \(m)"
        }
    }
}

/// Where connection secrets (engine keys, the Claude key, Google clients and sign-ins) are kept: one item in the
/// macOS Keychain (service "FloatBoard", account "credentials") holding a JSON list of name → secret.
/// Before Keychain, they were in a private file (`google-credentials.json`); the first read moves them into the
/// Keychain, checks the copy, and only then deletes the file.
/// `FLOATBOARD_CREDS` (checks) uses a throwaway file instead, so checks never touch the Keychain.
/// "Nothing saved yet" is an empty set; a store that exists but cannot be read is an error, so a damaged one is never
/// silently overwritten with an empty one.
public enum Credentials {
    /// The file used when `FLOATBOARD_CREDS` is set, and the old file that is moved into the Keychain otherwise.
    public static var url: URL { LocalData.credentials }
    /// True when the secrets live in the private file: in checks (`FLOATBOARD_CREDS`), and in every build without an Apple
    /// Developer team (built from source, ad-hoc or with a local certificate). For those, macOS ties Keychain access to
    /// the exact build, so each rebuild would ask for the Keychain password again and hold the app at launch.
    public static var usesFile: Bool {
        ProcessInfo.processInfo.environment[LocalData.credentialsEnv] != nil || !hasTeamID
    }

    /// Whether this running app is signed by an Apple Developer team (Developer ID builds).
    public static let hasTeamID: Bool = {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return !((dict[kSecCodeInfoTeamIdentifier as String] as? String) ?? "").isEmpty
    }()
    static let service = "FloatBoard", account = "credentials"

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
        if usesFile {
            if !fileExists, ProcessInfo.processInfo.environment[LocalData.credentialsEnv] == nil,
               let data = try Keychain.read(service: service, account: account) {
                // Keys kept in the Keychain by an earlier build move back to the private file, once.
                let dict = try decode(data)
                try save(dict)
                Keychain.delete(service: service, account: account)
                return dict
            }
            guard fileExists else { return [:] }
            let dict = try decode(try readFile())
            cache = dict
            return dict
        }
        if let data = try Keychain.read(service: service, account: account) {
            let dict = try decode(data)
            cache = dict
            return dict
        }
        // Nothing in the Keychain yet: move the old file in, if there is one.
        guard fileExists else { return [:] }
        let dict = try decode(try readFile())
        try save(dict)
        guard let back = try Keychain.read(service: service, account: account), try decode(back) == dict else {
            throw CredentialsError.unwritable("the Keychain copy didn't match the file, so the file was kept")
        }
        do { try FileManager.default.removeItem(at: url) } catch {
            throw CredentialsError.unwritable("moved to the Keychain, but the old file could not be deleted: \(error)")
        }
        return dict
    }

    private static func readFile() throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw CredentialsError.unreadable("\(error)") }
    }

    private static func decode(_ data: Data) throws -> [String: String] {
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw CredentialsError.unreadable("not a list of text values")
            }
            return dict
        } catch let e as CredentialsError { throw e } catch { throw CredentialsError.unreadable("\(error)") }
    }

    public static func get(_ key: String) throws -> String? { try all()[key] }

    public static func set(_ value: String, _ key: String) throws { var d = try all(); d[key] = value; try save(d) }

    public static func delete(_ key: String) throws { var d = try all(); d[key] = nil; try save(d) }

    public static func save(_ dict: [String: String]) throws {
        if !usesFile {
            let data: Data
            do { data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) } catch {
                throw CredentialsError.unwritable("\(error)")
            }
            try Keychain.write(data, service: service, account: account)
            cache = dict
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            cache = dict
        } catch { throw CredentialsError.unwritable("\(error)") }
    }
}

/// The few Keychain calls FloatBoard needs: one generic-password item per (service, account).
enum Keychain {
    static func read(service: String, account: String) throws -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        // Asleep (a background "dark wake") or locked: not an error, the next try works.
        if [errSecInteractionNotAllowed, -25320, -25330].contains(st) { throw CredentialsError.unavailable(message(st)) }
        guard st == errSecSuccess, let data = out as? Data else {
            throw CredentialsError.unreadable("Keychain: \(message(st))")
        }
        return data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        var st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "FloatBoard keys"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw CredentialsError.unwritable("Keychain: \(message(st))") }
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    static func message(_ st: OSStatus) -> String {
        (SecCopyErrorMessageString(st, nil) as String?) ?? "error \(st)"
    }
}
