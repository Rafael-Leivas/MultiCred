import Foundation
import XCTest
@testable import MultiCredCore

final class ManagedBlockTests: XCTestCase {
    func testAppendRemoveRoundTrip() throws {
        let original = "export A=1\n"
        let installed = try ManagedBlock.appendAtEnd("BODY", to: original)
        XCTAssertEqual(installed, "export A=1\n\n# >>> MultiCred >>>\nBODY\n# <<< MultiCred <<<\n")
        XCTAssertEqual(try ManagedBlock.appendAtEnd("BODY", to: installed), installed, "idempotent")
        XCTAssertEqual(try ManagedBlock.remove(from: installed), original)
        XCTAssertTrue(ManagedBlock.isLast(in: installed))
        XCTAssertFalse(ManagedBlock.isLast(in: installed + "[user]\n\temail = x\n"))
    }

    func testEmptyFileAndUnterminatedBlock() throws {
        XCTAssertEqual(try ManagedBlock.appendAtEnd("B", to: ""), "# >>> MultiCred >>>\nB\n# <<< MultiCred <<<\n")
        XCTAssertThrowsError(try ManagedBlock.remove(from: "a\n# >>> MultiCred >>>\nB\n")) {
            XCTAssertEqual($0 as? ManagedBlock.BlockError, .unterminated)
        }
    }
}

final class LegacyMigrationTests: SafeTestCase {
    /// Exactly what ~/Perfis/instalar.sh appended.
    static let legacyZshrc = """
    export PATH="$HOME/.local/bin:$PATH"

    # Perfis trabalho/pessoal
    [ -f "$HOME/Perfis/claude-env.sh" ] && source "$HOME/Perfis/claude-env.sh"

    """

    static let legacyGitconfig = """
    [core]
    \teditor = vim

    [include]
    \tpath = ~/Perfis/git-atual.gitconfig

    """

    func testRemovesOnlyTheLegacyLines() {
        XCTAssertEqual(LegacyMigration.removeLegacyLines(from: Self.legacyZshrc), "export PATH=\"$HOME/.local/bin:$PATH\"\n")
        XCTAssertEqual(LegacyMigration.removeLegacyLines(from: Self.legacyGitconfig), "[core]\n\teditor = vim\n")
    }

    func testKeepsIncludeSectionsWithOtherPaths() {
        let text = "[include]\n\tpath = ~/Perfis/git-atual.gitconfig\n\tpath = ~/.gitconfig.local\n"
        XCTAssertEqual(LegacyMigration.removeLegacyLines(from: text), "[include]\n\tpath = ~/.gitconfig.local\n")
    }

    func testFindingsAndImportOfPerfisConf() throws {
        try Data(Self.legacyZshrc.utf8).write(to: home.appendingPathComponent(".zshrc"))
        try Data(Self.legacyGitconfig.utf8).write(to: home.appendingPathComponent(".gitconfig"))
        let folder = LegacyMigration.folder(environment: environment)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        # comment
        TRABALHO_GIT_NOME="NPU-Rafael"
        TRABALHO_GIT_EMAIL="r@work.example"
        TRABALHO_GH_USUARIO="NPU-Rafael"
        TRABALHO_SSH_CHAVE=""          # opcional
        PESSOAL_GIT_NOME="Rafael"
        PESSOAL_GIT_EMAIL="r@gmail.com"
        PESSOAL_GH_USUARIO="Rafael-L"
        PESSOAL_SSH_CHAVE="~/.ssh/id_pessoal"
        PESSOAL_CLAUDE_DIR="$HOME/.claude-pessoal"
        EVIL=$(touch /tmp/never)
        """.utf8).write(to: folder.appendingPathComponent("perfis.conf"))
        try Data("pessoal\n".utf8).write(to: folder.appendingPathComponent("atual"))

        XCTAssertEqual(LegacyMigration.findings(environment: environment).map(\.file.lastPathComponent).sorted(), [".gitconfig", ".zshrc"])
        let profiles = LegacyMigration.importProfiles(environment: environment)
        XCTAssertEqual(profiles.map(\.key), ["TRABALHO", "PESSOAL"])
        XCTAssertEqual(profiles[0].displayName, "Trabalho")
        XCTAssertNil(profiles[0].sshKey)
        XCTAssertNil(profiles[0].claudeDir, "no CLAUDE_DIR = default account")
        XCTAssertEqual(profiles[1].sshKey, home.path + "/.ssh/id_pessoal")
        XCTAssertEqual(profiles[1].claudeDir, home.path + "/.claude-pessoal")
        XCTAssertEqual(LegacyMigration.activeProfileKey(environment: environment), "PESSOAL")
    }
}

final class InstallerTests: RealToolTestCase {
    private var installer: Installer { Installer(environment: environment) }
    private var paths: AppPaths { AppPaths(environment: environment) }
    private var zshrc: URL { home.appendingPathComponent(".zshrc") }
    private var gitconfig: URL { home.appendingPathComponent(".gitconfig") }

    func testFreshInstallWritesBlocksBackupsAndManifest() throws {
        try write("export A=1\n", to: zshrc)
        let preview = try installer.preview(InstallOptions(shells: [.zsh], removeLegacy: false))
        XCTAssertEqual(preview.map(\.path), ["~/.zshrc", "~/.gitconfig"])
        XCTAssertEqual(preview.map(\.kind), [.modify, .create])
        XCTAssertTrue(preview[0].addedLines.contains(Integrations.rcBlock(for: .zsh)))

        let manifest = try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))

        XCTAssertTrue(try read(zshrc).hasPrefix("export A=1\n\n# >>> MultiCred >>>\n"))
        XCTAssertTrue(ManagedBlock.isLast(in: try read(gitconfig)))
        XCTAssertEqual(try read(paths.hook(.zsh)), ShellHookRenderer.render(.zsh))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hook(.bash).path))
        XCTAssertEqual(try read(paths.gitconfig), GitConfigRenderer.header)

        let zshEntry = try XCTUnwrap(manifest.files.first { $0.path == zshrc.path })
        XCTAssertFalse(zshEntry.createdByMultiCred)
        XCTAssertEqual(try read(URL(fileURLWithPath: try XCTUnwrap(zshEntry.backup))), "export A=1\n")
        XCTAssertEqual(manifest.files.first { $0.path == gitconfig.path }?.createdByMultiCred, true)
        XCTAssertEqual(installer.manifest()?.shells, [.zsh])
    }

    func testInstallIsIdempotent() throws {
        try write("export A=1\n", to: zshrc)
        try installer.apply(InstallOptions(shells: [.zsh, .bash], removeLegacy: false))
        let first = try [zshrc, gitconfig, home.appendingPathComponent(".bashrc")].map { try read($0) }
        XCTAssertEqual(try installer.preview(InstallOptions(shells: [.zsh, .bash], removeLegacy: false)), [])
        try installer.apply(InstallOptions(shells: [.zsh, .bash], removeLegacy: false))
        XCTAssertEqual(try [zshrc, gitconfig, home.appendingPathComponent(".bashrc")].map { try read($0) }, first)
    }

    func testLegacyRemovalIsOptional() throws {
        try write(LegacyMigrationTests.legacyZshrc, to: zshrc)
        try write(LegacyMigrationTests.legacyGitconfig, to: gitconfig)

        try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        XCTAssertTrue(try read(zshrc).contains("Perfis/claude-env.sh"))

        let preview = try installer.preview(InstallOptions(shells: [.zsh], removeLegacy: true))
        XCTAssertTrue(preview.contains { $0.removedLines.contains { $0.contains("Perfis/claude-env.sh") } })
        try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: true))
        XCTAssertFalse(try read(zshrc).contains("Perfis/claude-env.sh"))
        XCTAssertFalse(try read(gitconfig).contains("Perfis/git-atual"))
        XCTAssertTrue(try read(gitconfig).hasPrefix("[core]\n\teditor = vim\n"))
        XCTAssertEqual(LegacyMigration.findings(environment: environment), [])
    }

    func testDisablingAShellRemovesItsBlock() throws {
        try installer.apply(InstallOptions(shells: [.zsh, .bash, .fish], removeLegacy: false))
        XCTAssertTrue(ManagedBlock.contains(try read(home.appendingPathComponent(".bash_profile"))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Integrations.fishConfFile(environment: environment).path))

        try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        XCTAssertFalse(ManagedBlock.contains(try read(home.appendingPathComponent(".bash_profile"))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Integrations.fishConfFile(environment: environment).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hook(.fish).path))
    }

    func testSymlinkedDotfileIsEditedThroughTheLink() throws {
        let real = home.appendingPathComponent("dotfiles/zshrc")
        try write("export B=2\n", to: real)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: real)
        try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        XCTAssertTrue(ManagedBlock.contains(try read(real)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: zshrc.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testHandEditedMarkerStopsBeforeWritingAnything() throws {
        try write("x\n\(ManagedBlock.begin)\nbroken\n", to: zshrc)
        XCTAssertThrowsError(try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))) {
            XCTAssertEqual($0 as? InstallError, .markerMismatch(path: "~/.zshrc"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitconfig.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
    }

    func testFailureMidwayRestoresEverythingWritten() throws {
        try write("export A=1\n", to: zshrc)
        // conf.d is a file, so writing the fish file fails after .zshrc was written.
        try write("not a directory", to: home.appendingPathComponent(".config/fish/conf.d"))
        XCTAssertThrowsError(try installer.apply(InstallOptions(shells: [.zsh, .fish], removeLegacy: false)))
        XCTAssertEqual(try read(zshrc), "export A=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitconfig.path))
    }

    /// The whole chain with real tools: install, switch, then an interactive zsh
    /// reading the installed ~/.zshrc and git reading the installed include.
    func testInstalledHooksDriveRealZshAndGit() async throws {
        try write("export KEEP=yes\n", to: zshrc)
        try installer.apply(InstallOptions(shells: [.zsh], removeLegacy: false))

        let claudeDir = home.appendingPathComponent(".claude-pessoal")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let identity = GitIdentity(nickname: "P", name: "Pessoal", email: "p@example.com", color: .orange)
        let claude = ClaudeAccount(nickname: "P", color: .orange, configDir: claudeDir.path)
        let profile = Profile(name: "Pessoal", color: .orange, gitIdentityId: identity.id, claudeAccountId: claude.id)
        let config = Config(gitIdentities: [identity], claudeAccounts: [claude], profiles: [profile])
        runner.on("launchctl", stdout: "")
        _ = try await SwitchEngine(environment: environment, tools: FakeTools()).switchProfile(profile.id, in: config)

        let zsh = try await run("/bin/zsh", ["-i", "-c", "print -r -- \"$KEEP|$CLAUDE_CONFIG_DIR\""], extraEnvironment: ["TERM": "dumb"])
        XCTAssertTrue(zsh.stdout.hasSuffix("yes|\(claudeDir.path)\n"), zsh.stdout + zsh.stderr)

        let git = try await run("/usr/bin/git", ["config", "--get", "user.email"])
        XCTAssertEqual(git.stdout, "p@example.com\n")
    }
}

final class UninstallerTests: RealToolTestCase {
    func testUninstallRestoresFilesAndRemovesEverything() async throws {
        let zshrc = home.appendingPathComponent(".zshrc")
        try write("export A=1\n", to: zshrc)
        let installer = Installer(environment: environment)
        try installer.apply(InstallOptions(shells: [.zsh, .bash, .fish], removeLegacy: false))
        try keychain.setSecret(Data("sk".utf8), account: UUID().uuidString)
        runner.on("launchctl", ["unsetenv"])

        let preview = Uninstaller(environment: environment).preview()
        XCTAssertTrue(preview.contains { $0.path == "~/.zshrc" })
        XCTAssertTrue(preview.contains { $0.path == "~/Library/Application Support/MultiCred" && $0.kind == .delete })

        let report = await Uninstaller(environment: environment).apply()

        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(try read(zshrc), "export A=1\n", "back to the original bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path), "created by MultiCred and now empty")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gitconfig").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Integrations.fishConfFile(environment: environment).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.appSupportDirectory.path))
        XCTAssertEqual(try keychain.allAccounts(), [])
        XCTAssertTrue(runner.requests.contains { $0.arguments == ["unsetenv", "CLAUDE_CONFIG_DIR"] })

        let kept = try XCTUnwrap(report.backupsKeptAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.expandTilde(kept)))
    }

    func testUserEditsOutsideTheBlockSurvive() async throws {
        let zshrc = home.appendingPathComponent(".zshrc")
        try write("export A=1\n", to: zshrc)
        try Installer(environment: environment).apply(InstallOptions(shells: [.zsh], removeLegacy: false))
        try write(try read(zshrc) + "alias ll='ls -la'\n", to: zshrc)
        runner.on("launchctl")
        _ = await Uninstaller(environment: environment).apply()
        XCTAssertEqual(try read(zshrc), "export A=1\nalias ll='ls -la'\n")
    }

    func testBrokenMarkerBecomesAManualStep() async throws {
        let zshrc = home.appendingPathComponent(".zshrc")
        try write("x\n\(ManagedBlock.begin)\nbroken\n", to: zshrc)
        runner.on("launchctl")
        let report = await Uninstaller(environment: environment).apply()
        XCTAssertEqual(report.manualSteps.count, 1)
        XCTAssertEqual(try read(zshrc), "x\n\(ManagedBlock.begin)\nbroken\n")
    }
}
