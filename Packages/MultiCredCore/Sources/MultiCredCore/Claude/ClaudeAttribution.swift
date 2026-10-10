import Foundation

/// Whether Claude Code adds itself as co-author ("Co-Authored-By: Claude") to
/// commits and PRs. Claude Code only reads this from settings (no environment
/// variable): `"attribution": {"commit": "", "pr": ""}` hides it. MultiCred
/// writes that exact value into the profile's Claude folder `settings.json`
/// when the profile's GitHub account opts out, and removes only that exact
/// value when it opts back in, so attribution the user wrote by hand is kept.
public enum ClaudeAttribution {
    /// The value MultiCred writes to hide attribution.
    public static let hidden: [String: String] = ["commit": "", "pr": ""]

    public static func settingsFile(configDir: String?, environment: SystemEnvironment) -> URL {
        URL(fileURLWithPath: configDir ?? ClaudePaths.defaultConfigDir(environment: environment), isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public enum UpdateError: Error, Equatable {
        /// settings.json exists but is not a JSON object; MultiCred leaves it alone.
        case unreadableSettings
    }

    /// New settings.json content, or nil when nothing has to change.
    public static func updated(_ current: Data?, coAuthor: Bool) throws -> Data? {
        var object: [String: Any] = [:]
        if let current, !current.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else {
                throw UpdateError.unreadableSettings
            }
            object = parsed
        }

        if coAuthor {
            // Opt back in: undo only what MultiCred wrote.
            guard isHiddenValue(object["attribution"]) else { return nil }
            object.removeValue(forKey: "attribution")
        } else {
            if isHiddenValue(object["attribution"]) { return nil }
            object["attribution"] = hidden
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func isHiddenValue(_ value: Any?) -> Bool {
        (value as? [String: Any]).map { dict in
            dict.count == 2 && (dict["commit"] as? String) == "" && (dict["pr"] as? String) == ""
        } ?? false
    }
}
