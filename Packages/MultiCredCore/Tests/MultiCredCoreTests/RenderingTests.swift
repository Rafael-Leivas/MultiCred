import Foundation
import XCTest
@testable import MultiCredCore

/// Renderer tests read the generated files back with the real tools
/// (/usr/bin/git, /bin/sh, /bin/zsh, /bin/bash), always inside the temporary
/// HOME and with rc files disabled, so nothing outside the test directory is read
/// or written.
class RealToolTestCase: SafeTestCase {
    func run(_ executable: String, _ arguments: [String], extraEnvironment: [String: String] = [:]) async throws -> CommandResult {
        var env = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LANG": "en_US.UTF-8",
        ]
        env.merge(extraEnvironment) { $1 }
        return try await ProcessRunner().run(CommandRequest(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: env,
            currentDirectory: home,
            timeout: .seconds(20)
        ))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

final class GitConfigRendererTests: RealToolTestCase {
    private func gitGet(_ key: String, file: URL) async throws -> String {
        try await run("/usr/bin/git", ["config", "--file", file.path, "--get", key]).stdout.trimmingCharacters(in: .newlines)
    }

    func testValuesSurviveGitParsing() async throws {
        let identity = GitIdentity(
            nickname: "x",
            name: #"Rafael "Rafa" Leivas \ ç # not a comment ; neither"#,
            email: "rafael+tag@work.example",
            sshKeyPath: "~/.ssh/id work's key",
            color: .indigo
        )
        let file = home.appendingPathComponent("gitconfig")
        try write(GitConfigRenderer.render(identity, environment: environment), to: file)

        let name = try await gitGet("user.name", file: file)
        let email = try await gitGet("user.email", file: file)
        let ssh = try await gitGet("core.sshCommand", file: file)
        XCTAssertEqual(name, identity.name)
        XCTAssertEqual(email, identity.email)
        XCTAssertEqual(ssh, "ssh -i '\(home.path)/.ssh/id work'\\''s key' -o IdentitiesOnly=yes")
    }

    func testEmptyIdentityRendersOnlyTheHeader() async throws {
        let file = home.appendingPathComponent("gitconfig")
        try write(GitConfigRenderer.render(nil, environment: environment), to: file)
        let result = try await run("/usr/bin/git", ["config", "--file", file.path, "--list"])
        XCTAssertEqual(result.stdout, "")
    }

    func testIncludeAtEndOfGlobalConfigWins() async throws {
        let identity = GitIdentity(nickname: "p", name: "Pessoal", email: "p@example.com", color: .orange)
        let paths = AppPaths(environment: environment)
        try write(GitConfigRenderer.render(identity, environment: environment), to: paths.gitconfig)
        try write("""
        [user]
        \tname = Old Name
        \temail = old@example.com
        [include]
        \tpath = "~/Library/Application Support/MultiCred/gitconfig"

        """, to: home.appendingPathComponent(".gitconfig"))

        // What `git commit` sees: all scopes, includes followed.
        let effective = try await run("/usr/bin/git", ["config", "--get", "user.email"])
        XCTAssertEqual(effective.stdout, "p@example.com\n")

        // Pitfall for the Verifier: a scoped read ignores includes unless asked.
        let scopedWithoutIncludes = try await run("/usr/bin/git", ["config", "--global", "--get", "user.email"])
        XCTAssertEqual(scopedWithoutIncludes.stdout, "old@example.com\n")
        let scopedWithIncludes = try await run("/usr/bin/git", ["config", "--global", "--includes", "--get", "user.email"])
        XCTAssertEqual(scopedWithIncludes.stdout, "p@example.com\n")
    }

    func testUserSettingAfterTheIncludeOverridesIt() async throws {
        let identity = GitIdentity(nickname: "p", name: "Pessoal", email: "p@example.com", color: .orange)
        let paths = AppPaths(environment: environment)
        try write(GitConfigRenderer.render(identity, environment: environment), to: paths.gitconfig)
        try write("""
        [include]
        \tpath = "~/Library/Application Support/MultiCred/gitconfig"
        [user]
        \temail = later@example.com

        """, to: home.appendingPathComponent(".gitconfig"))
        let result = try await run("/usr/bin/git", ["config", "--show-origin", "--get", "user.email"])
        XCTAssertTrue(result.stdout.hasSuffix("\tlater@example.com\n"), result.stdout)
        XCTAssertTrue(result.stdout.hasPrefix("file:\(home.path)/.gitconfig"), "the Verifier can point at the overriding file")
    }
}

final class EnvFileRendererTests: RealToolTestCase {
    private let knownAccount = "6B1F4C1E-0D7A-4E0B-9A3E-3C1C2B0F9A11"
    private var fakeSecurity: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Stands in for /usr/bin/security: answers only for the known account.
        fakeSecurity = home.appendingPathComponent("fake-security")
        try write("""
        #!/bin/sh
        [ "$1" = find-generic-password ] && [ "$3" = app.multicred.apikey ] && [ "$5" = \(knownAccount) ] && [ "$6" = -w ] || exit 44
        printf 'sk-test-value'

        """, to: fakeSecurity)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSecurity.path)
    }

    private func environment(claude: ClaudeTarget, keys: [ShellEnvironment.APIKeyExport]) -> ShellEnvironment {
        ShellEnvironment(generation: 7, managedVars: ["GEMINI_API_KEY", "OPENAI_API_KEY"], claude: claude, apiKeys: keys)
    }

    private func sourceAndPrint(_ envFile: URL, preset: String = "") async throws -> String {
        let script = """
        \(preset)
        . "$1"
        printf '%s|%s|%s' "${CLAUDE_CONFIG_DIR-unset}" "${OPENAI_API_KEY-unset}" "${GEMINI_API_KEY-unset}"
        """
        return try await run("/bin/sh", ["-c", script, "sh", envFile.path]).stdout
    }

    func testExportsDirectoryAndKeyAndUnsetsOtherManagedVars() async throws {
        let file = home.appendingPathComponent("env.sh")
        let env = environment(claude: .directory(home.path + "/.claude-x y'z"), keys: [.init(envVar: "OPENAI_API_KEY", keychainAccount: knownAccount)])
        try write(EnvFileRenderer.renderPOSIX(env, securityTool: fakeSecurity.path), to: file)
        let output = try await sourceAndPrint(file, preset: "export GEMINI_API_KEY=leaked-from-previous-profile")
        XCTAssertEqual(output, "\(home.path)/.claude-x y'z|sk-test-value|unset")
    }

    func testDefaultAccountUnsetsVariableAndMissingKeyStaysUnset() async throws {
        let file = home.appendingPathComponent("env.sh")
        let env = environment(claude: .defaultAccount, keys: [.init(envVar: "OPENAI_API_KEY", keychainAccount: UUID().uuidString)])
        try write(EnvFileRenderer.renderPOSIX(env, securityTool: fakeSecurity.path), to: file)
        let output = try await sourceAndPrint(file, preset: "export CLAUDE_CONFIG_DIR=/old")
        XCTAssertEqual(output, "unset|unset|unset")
    }

    func testUnchangedLeavesClaudeVariableAlone() async throws {
        let file = home.appendingPathComponent("env.sh")
        try write(EnvFileRenderer.renderPOSIX(environment(claude: .unchanged, keys: []), securityTool: fakeSecurity.path), to: file)
        let output = try await sourceAndPrint(file, preset: "export CLAUDE_CONFIG_DIR=/kept")
        XCTAssertEqual(output, "/kept|unset|unset")
    }

    func testRealSecurityPathIsTheDefault() {
        let text = EnvFileRenderer.renderPOSIX(environment(claude: .unchanged, keys: [.init(envVar: "OPENAI_API_KEY", keychainAccount: knownAccount)]))
        XCTAssertTrue(text.contains("'/usr/bin/security' find-generic-password -s 'app.multicred.apikey' -a '\(knownAccount)' -w"))
        XCTAssertTrue(text.hasPrefix("# Generated by MultiCred. Do not edit. generation=7\n"))
    }

    func testFishRendering() throws {
        let text = EnvFileRenderer.renderFish(environment(claude: .directory("/a b/it's"), keys: [.init(envVar: "OPENAI_API_KEY", keychainAccount: knownAccount)]))
        XCTAssertTrue(text.contains("set -gx CLAUDE_CONFIG_DIR '/a b/it\\'s'"))
        XCTAssertTrue(text.contains("set -q OPENAI_API_KEY; and set -e -g OPENAI_API_KEY"))
        XCTAssertTrue(text.contains("if test $status -eq 0\n    set -gx OPENAI_API_KEY $__multicred_value\nelse"))
    }

    func testFishFileWithRealFishWhenInstalled() async throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(fish == nil, "fish is not installed")
        let file = home.appendingPathComponent("env.fish")
        let env = environment(claude: .directory("/a b"), keys: [.init(envVar: "OPENAI_API_KEY", keychainAccount: knownAccount)])
        try write(EnvFileRenderer.renderFish(env, securityTool: fakeSecurity.path), to: file)
        let output = try await run(fish!, ["--no-config", "-c", "set -gx GEMINI_API_KEY old; source $argv[1]; printf '%s|%s|%s' $CLAUDE_CONFIG_DIR $OPENAI_API_KEY (set -q GEMINI_API_KEY; and echo set; or echo unset)", file.path])
        XCTAssertEqual(output.stdout, "/a b|sk-test-value|unset")
    }
}

final class ShellHookTests: RealToolTestCase {
    private var paths: AppPaths { AppPaths(environment: environment) }

    private func prepare(_ shell: ShellKind, claudeDir: String, generation: Int) throws {
        try write(ShellHookRenderer.render(shell), to: paths.hook(shell))
        try write("export CLAUDE_CONFIG_DIR='\(claudeDir)'\n", to: paths.envSh)
        try write("\(generation)\n", to: paths.generation)
    }

    func testZshHookFollowsGenerationChanges() async throws {
        try prepare(.zsh, claudeDir: "/a", generation: 1)
        let script = """
        source "$1"
        print -r -- "A=${CLAUDE_CONFIG_DIR-unset}"
        print -r -- "export CLAUDE_CONFIG_DIR='/b'" > "$2/env.sh"
        _multicred_apply; print -r -- "same-generation=$CLAUDE_CONFIG_DIR"
        print 2 > "$2/generation"
        _multicred_apply; print -r -- "B=$CLAUDE_CONFIG_DIR"
        source "$1"
        print -r -- "registered=${#${(@M)precmd_functions:#_multicred_apply}}"
        """
        let result = try await run("/bin/zsh", ["-f", "-c", script, "zsh", paths.hook(.zsh).path, paths.root.path])
        XCTAssertEqual(result.stdout, "A=/a\nsame-generation=/a\nB=/b\nregistered=1\n", result.stderr)
    }

    func testZshHookIsSilentWithoutFiles() async throws {
        try write(ShellHookRenderer.render(.zsh), to: paths.hook(.zsh))
        let result = try await run("/bin/zsh", ["-f", "-c", "source \"$1\"; _multicred_apply; print -r -- ok", "zsh", paths.hook(.zsh).path])
        XCTAssertEqual(result.stdout, "ok\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testBashHookWithStringPromptCommand() async throws {
        try prepare(.bash, claudeDir: "/a", generation: 1)
        let script = """
        PROMPT_COMMAND='history -a'
        . "$1"
        . "$1"
        printf 'A=%s\\n' "${CLAUDE_CONFIG_DIR-unset}"
        printf 'PC=%s\\n' "$PROMPT_COMMAND"
        printf "export CLAUDE_CONFIG_DIR='/b'\\n" > "$2/env.sh"
        printf '2' > "$2/generation"
        _multicred_apply
        printf 'B=%s\\n' "$CLAUDE_CONFIG_DIR"
        """
        let result = try await run("/bin/bash", ["--norc", "--noprofile", "-c", script, "bash", paths.hook(.bash).path, paths.root.path])
        XCTAssertEqual(result.stdout, "A=/a\nPC=_multicred_apply;history -a\nB=/b\n", result.stderr)
    }

    func testBashHookWithArrayPromptCommandWhenModernBashExists() async throws {
        let bash = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(bash == nil, "bash 5 is not installed")
        try prepare(.bash, claudeDir: "/a", generation: 1)
        let script = """
        PROMPT_COMMAND=('history -a')
        . "$1"; . "$1"
        printf '%s\\n' "${PROMPT_COMMAND[@]}"
        """
        let result = try await run(bash!, ["--norc", "--noprofile", "-c", script, "bash", paths.hook(.bash).path])
        XCTAssertEqual(result.stdout, "_multicred_apply\nhistory -a\n", result.stderr)
    }

    func testHooksUseHomeRelativePathsOnly() {
        for shell in ShellKind.allCases {
            let text = ShellHookRenderer.render(shell)
            XCTAssertTrue(text.contains("$HOME/Library/Application Support/MultiCred"), shell.rawValue)
            XCTAssertFalse(text.contains("/Users/"), shell.rawValue)
        }
    }
}
