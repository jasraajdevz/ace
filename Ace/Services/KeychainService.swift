//
//  KeychainService.swift
//  Ace
//
//  Where the OpenAI key lives (§5, §10).
//
//  The rules, and none of them bend:
//    • The key is written to the Keychain and nowhere else. Not `UserDefaults`,
//      not a plist, not a file, never in source, never in a log line.
//    • `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — it never syncs to
//      iCloud and never leaves this device, so a stolen backup is not a stolen key.
//    • Nothing in the app ever prints or displays the key. Settings shows a
//      masked fingerprint (`sk-…a91f`) so the student can tell *which* key is
//      installed without it being shoulder-surfable.
//

import Foundation
import Security

// MARK: - The seam

/// Where the key lives.
///
/// A protocol rather than a bare `enum` so the key lifecycle — add, replace,
/// remove, and what the provider does in response — can be exercised in tests
/// without touching the real login keychain, which in a headless process either
/// fails or prompts.
protocol SecretStore: Sendable {
    @discardableResult func store(_ key: String) -> Bool
    func load() -> String?
    @discardableResult func delete() -> Bool
}

extension SecretStore {
    var hasKey: Bool { load() != nil }
}

/// The production store.
struct KeychainSecretStore: SecretStore {
    func store(_ key: String) -> Bool { KeychainService.store(key) }
    func load() -> String? { KeychainService.load() }
    func delete() -> Bool { KeychainService.delete() }
}

/// An in-memory store, for tests. Never used by the app.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(seeded: String? = nil) { value = seeded }

    func store(_ key: String) -> Bool {
        lock.withLock { value = key.trimmed }
        return true
    }
    func load() -> String? { lock.withLock { value } }
    func delete() -> Bool {
        lock.withLock { value = nil }
        return true
    }
}

/// Reads and writes the API key.
enum KeychainService {

    private static let service = "com.acestudy.Ace"
    private static let account = "openai.api.key"

    // MARK: - Storing

    @discardableResult
    static func store(_ key: String) -> Bool {
        let trimmed = key.trimmed
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }

        // Delete-then-add rather than update: it's one code path instead of two,
        // and it can't leave a stale item behind if an update partially fails.
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Reading

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static var hasKey: Bool { load() != nil }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Key shape

/// Validation and masking. Pure string work, kept separate from the Keychain so
/// it can be tested without a keychain.
enum APIKeyFormat {

    /// A quick sanity check before we bother the network.
    ///
    /// Deliberately loose: OpenAI has shipped several key prefixes (`sk-`,
    /// `sk-proj-`, `sk-svcacct-`) and will ship more. Rejecting an unfamiliar
    /// but valid key is a worse failure than letting the API reject a bad one,
    /// so this only catches obvious mistakes — an empty box, a pasted URL, a
    /// truncated paste.
    static func validate(_ raw: String) -> KeyValidation {
        let key = raw.trimmed

        if key.isEmpty { return .empty }
        // Order matters: the more specific mistakes are checked first, so the
        // student gets the message that actually tells them what to do.
        if key.lowercased().hasPrefix("bearer ") { return .malformed("Just the key please — drop the “Bearer” part.") }
        if key.lowercased().hasPrefix("http") { return .malformed("That looks like a URL, not a key.") }
        if key.contains(" ") || key.contains("\n") { return .malformed("That has spaces in it — check the paste.") }
        if !key.hasPrefix("sk-") { return .malformed("OpenAI keys start with “sk-”.") }
        if key.count < 20 { return .malformed("That looks cut off — keys are much longer.") }
        return .looksValid
    }

    /// What Settings displays: enough to identify the key, not enough to use it.
    static func fingerprint(_ key: String) -> String {
        let trimmed = key.trimmed
        guard trimmed.count > 10 else { return "sk-…" }
        let prefix = trimmed.hasPrefix("sk-proj-") ? "sk-proj-"
            : (trimmed.hasPrefix("sk-svcacct-") ? "sk-svcacct-" : "sk-")
        return "\(prefix)…\(trimmed.suffix(4))"
    }
}

enum KeyValidation: Sendable, Equatable {
    case empty
    case malformed(String)
    case looksValid

    var isUsable: Bool { self == .looksValid }

    var message: String? {
        switch self {
        case .empty: nil
        case .malformed(let reason): reason
        case .looksValid: nil
        }
    }
}
