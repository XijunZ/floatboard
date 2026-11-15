import FloatBoardCore
import Foundation
import Security

public enum CredentialsError: Error, CustomStringConvertible {
    case unreadable(String), unwritable(String)
    public var description: String {
        switch self {
        case .unreadable(let m): return "The credentials file could not be read: \(m)"
        case .unwritable(let m): return "The credentials file could not be written: \(m)"
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
    /// True when the secrets live in a file: in checks (`FLOATBOARD_CREDS`), and in builds signed ad-hoc, where the
    /// Keychain would ask for permission again after every rebuild. Builds signed with a certificate (such as the local
    /// "FloatBoard Local Signing" one, see build-app.sh) keep the Keychain's permission across rebuilds.
    public static var usesFile: Bool {
        ProcessInfo.processInfo.environment[LocalData.credentialsEnv] != nil || !signedWithCertificate
    }

    /// Whether this running app is signed with a certificate (not ad-hoc and not unsigned).
    public static let signedWithCertificate: Bool = {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return !((dict[kSecCodeInfoCertificates as String] as? [Any]) ?? []).isEmpty
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

    static func message(_ st: OSStatus) -> String {
        (SecCopyErrorMessageString(st, nil) as String?) ?? "error \(st)"
    }
}
