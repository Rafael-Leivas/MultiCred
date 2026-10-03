import Foundation

/// Quoting helpers for text that ends up inside generated shell files or in
/// human-readable command previews.
public enum ShellQuoting {
    /// POSIX single-quote quoting: `it's` becomes `'it'\''s'`.
    /// Safe for zsh, bash and sh; nothing inside single quotes is expanded.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// fish single-quote quoting: only `\` and `'` are special inside single quotes.
    public static func fishSingleQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }

    /// Quotes only when needed, for display in logs and previews.
    static func quoteForDisplay(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return singleQuoted(value)
    }
}
