import Foundation

public struct UninstallReport: Equatable, Sendable {
    public var changedFiles: [String] = []
    /// Things the user must do by hand (a block edited beyond recognition).
    public var manualSteps: [String] = []
    /// Where the backups were moved, if there were any.
    public var backupsKeptAt: String?
    public var problems: [String] = []
}

/// Removes everything MultiCred added: the marked blocks (and only them), the
/// fish conf.d file, the launchd variable, the API keys in the Keychain and the
/// support folder. Backups are moved out of the folder before it is deleted.
/// Claude Code and gh logins are not touched; logging out of Claude accounts
/// created by MultiCred is a separate, explicit step in the app.
public struct Uninstaller: Sendable {
    let environment: SystemEnvironment
    let paths: AppPaths

    public init(environment: SystemEnvironment) {
        self.environment = environment
        paths = AppPaths(environment: environment)
    }

    /// Files that will change, for the confirmation screen.
    public func preview() -> [FileChange] {
        var changes: [FileChange] = []
        for file in Integrations.allBlockFiles(environment: environment) {
            guard let target = try? AtomicFileWriter.resolveTarget(file, followSymlink: true),
                  let text = try? String(contentsOf: target, encoding: .utf8),
                  let body = ManagedBlock.body(in: text)
            else { continue }
            changes.append(FileChange(
                path: environment.abbreviate(target.path),
                kind: .modify,
                addedLines: [],
                removedLines: [ManagedBlock.begin] + body.components(separatedBy: "\n") + [ManagedBlock.end]
            ))
        }
        let fish = Integrations.fishConfFile(environment: environment)
        if FileManager.default.fileExists(atPath: fish.path) {
            changes.append(FileChange(path: environment.abbreviate(fish.path), kind: .delete, addedLines: [], removedLines: []))
        }
        changes.append(FileChange(path: environment.abbreviate(paths.root.path), kind: .delete, addedLines: [], removedLines: []))
        return changes
    }

    public func apply() async -> UninstallReport {
        var report = UninstallReport()
        let manifest = Installer(environment: environment).manifest()

        for file in Integrations.allBlockFiles(environment: environment) {
            guard let target = try? AtomicFileWriter.resolveTarget(file, followSymlink: true),
                  let text = try? String(contentsOf: target, encoding: .utf8),
                  ManagedBlock.contains(text)
            else { continue }
            do {
                let cleaned = try ManagedBlock.remove(from: text)
                let createdByUs = manifest?.files.contains { $0.path == target.path && $0.createdByMultiCred } ?? false
                if createdByUs, cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try FileManager.default.removeItem(at: target)
                } else {
                    try AtomicFileWriter.write(Data(cleaned.utf8), to: target, followSymlink: true)
                }
                report.changedFiles.append(environment.abbreviate(target.path))
            } catch ManagedBlock.BlockError.unterminated {
                report.manualSteps.append("Remova à mão, em \(environment.abbreviate(target.path)), as linhas a partir de \"\(ManagedBlock.begin)\".")
            } catch {
                report.problems.append("\(environment.abbreviate(target.path)): \(error)")
            }
        }

        let fish = Integrations.fishConfFile(environment: environment)
        if let text = try? String(contentsOf: fish, encoding: .utf8), ManagedBlock.contains(text) {
            do {
                try FileManager.default.removeItem(at: fish)
                report.changedFiles.append(environment.abbreviate(fish.path))
            } catch {
                report.problems.append("\(environment.abbreviate(fish.path)): \(error)")
            }
        }

        // launchd: the variable only ever came from MultiCred's switches.
        let launchctl = Launchctl(runner: environment.runner, baseEnvironment: environment.baseProcessEnvironment(path: ["/usr/bin", "/bin"]))
        do {
            try await launchctl.unsetenv(SwitchEngine.claudeVariable)
        } catch {
            report.problems.append("launchctl unsetenv \(SwitchEngine.claudeVariable): \(error)")
        }

        do {
            for account in try environment.keychain.allAccounts() {
                try environment.keychain.deleteItem(account: account)
            }
        } catch {
            report.problems.append("Keychain: \(error)")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: paths.backups.path),
           let contents = try? fm.contentsOfDirectory(atPath: paths.backups.path), !contents.isEmpty {
            let destination = paths.root.deletingLastPathComponent()
                .appendingPathComponent("MultiCred-backups-\(Installer.stamp(environment.clock()))", isDirectory: true)
            do {
                try fm.moveItem(at: paths.backups, to: destination)
                report.backupsKeptAt = environment.abbreviate(destination.path)
            } catch {
                report.problems.append("backups: \(error)")
            }
        }
        if fm.fileExists(atPath: paths.root.path) {
            do {
                try fm.removeItem(at: paths.root)
            } catch {
                report.problems.append("\(environment.abbreviate(paths.root.path)): \(error)")
            }
        }
        return report
    }
}
