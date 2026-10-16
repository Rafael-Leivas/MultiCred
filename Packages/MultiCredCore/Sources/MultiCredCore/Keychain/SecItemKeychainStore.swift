import Foundation
import Security

/// Real Keychain store in the user's login keychain.
///
/// Items are **created by `/usr/bin/security`** (the same way Claude Code stores
/// its own credential), so the shell hook, which reads them with
/// `security find-generic-password -w`, gets the value without a password
/// prompt. Items created through `SecItemAdd` belong to the app's partition
/// (for an ad hoc build, its cdhash, which changes on every build), and then
/// macOS asks for the login password on each read by `security`.
///
/// The secret goes to `security -i` on stdin, hex encoded, never in argv.
/// Existence checks and listing use attributes only (no prompt). The app never
/// reads a value back.
public struct SecItemKeychainStore: KeychainStore {
    /// Label of items created by `security` (current scheme).
    public static let label = "MultiCred"
    /// Label of items created by older builds through SecItemAdd.
    public static let legacyLabel = "MultiCred API key"

    private let service: String
    private let tool: SecurityToolRunner

    public init(service: String = KeychainConstants.apiKeyService, toolPath: String = "/usr/bin/security", runner: any CommandRunner = ProcessRunner()) {
        self.service = service
        tool = SecurityToolRunner(toolPath: toolPath, runner: runner)
    }

    public func setSecret(_ value: Data, account: String) throws {
        try KeychainConstants.validate(account: account)
        guard !value.isEmpty else { throw KeychainError.emptySecret }

        // A legacy item cannot be updated into the tool's partition: replace it.
        if try label(of: account) == Self.legacyLabel {
            try check(SecItemDelete(baseQuery(account: account) as CFDictionary), allowNotFound: true)
        }
        // -U updates in place, so a failed write never loses the previous value.
        let command = SecurityToolCommand.add(service: service, account: account, label: Self.label, secret: value)
        let result = try runTool(command)
        guard result.exitCode == 0, result.standardError.isEmpty, try containsItem(account: account) else {
            throw KeychainError.toolFailed(String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func containsItem(account: String) throws -> Bool {
        try label(of: account) != nil
    }

    public func isLegacyItem(account: String) throws -> Bool {
        try label(of: account) == Self.legacyLabel
    }

    public func deleteItem(account: String) throws {
        switch try label(of: account) {
        case nil:
            return
        case Self.legacyLabel:
            try check(SecItemDelete(baseQuery(account: account) as CFDictionary), allowNotFound: true)
        default:
            // Created by `security`: delete with it as well.
            let result = try runTool(SecurityToolCommand.delete(service: service, account: account))
            if result.exitCode != 0, try containsItem(account: account) {
                throw KeychainError.toolFailed(String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    public func allAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Label of the item (attributes only, no prompt); nil when missing.
    private func label(of account: String) throws -> String?? {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return .some((result as? [String: Any])?[kSecAttrLabel as String] as? String)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func runTool(_ command: SecurityToolCommand) throws -> CommandResult {
        try tool.run(command.arguments, standardInput: command.standardInput)
    }

    private func check(_ status: OSStatus, allowNotFound: Bool = false) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound where allowNotFound: return
        case errSecUserCanceled: throw KeychainError.userCanceled
        case errSecAuthFailed, errSecInteractionNotAllowed: throw KeychainError.accessDenied
        default: throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// `security` invocations, kept pure so tests can check that a secret never
/// appears in the arguments.
public struct SecurityToolCommand: Equatable, Sendable {
    public let arguments: [String]
    public let standardInput: Data?

    /// `security -i` reads one command per line from stdin; -X takes the
    /// password as hex, so the secret is neither in argv nor needs quoting.
    public static func add(service: String, account: String, label: String, secret: Data) -> SecurityToolCommand {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -s \(service) -a \(account) -l \(label) -X \(hex)\n"
        return SecurityToolCommand(arguments: ["-i"], standardInput: Data(line.utf8))
    }

    public static func delete(service: String, account: String) -> SecurityToolCommand {
        SecurityToolCommand(arguments: ["delete-generic-password", "-s", service, "-a", account], standardInput: nil)
    }
}
