import Foundation

/// Stand-in for `claude auth login` in the app's test mode. It prints what the
/// real CLI printed in the Phase 1 spike, waits for a code, and on success writes
/// a fake `oauthAccount` into the account's `.claude.json` so status checks see a
/// logged-in account. It refuses to write anywhere outside `$HOME`, which in test
/// mode is the sandbox. Codes starting with "erro" or containing "expir" fail.
public enum LoginSimulator {
    public static let executable = "/bin/sh"
    public static let simulatedEmail = "simulado@example.com"

    public static var arguments: [String] { ["-c", script] }

    static let script = #"""
    printf '[MODO DE TESTE: simulação do claude auth login]\r\n'
    printf 'Opening browser to sign in...\r\n'
    sleep 1
    printf "If the browser didn't open, visit: https://example.invalid/oauth/authorize?simulado=1\r\n"
    printf 'Paste code here if prompted > '
    IFS= read -r code
    sleep 1
    case "$code" in
      erro*|*expir*) printf '\r\nError: Invalid code or expired\r\n'; exit 1 ;;
    esac
    target="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    case "$target" in
      "$HOME"/*) ;;
      *) printf 'Refusing to write outside the test home\r\n'; exit 3 ;;
    esac
    printf '{"oauthAccount":{"emailAddress":"simulado@example.com"}}' > "$target"
    printf 'Login successful.\r\n'
    """#
}
