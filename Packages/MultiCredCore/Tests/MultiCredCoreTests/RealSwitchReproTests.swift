import Foundation
import XCTest
@testable import MultiCredCore

/// Runs the real switch engine against the real system with the user's own
/// MultiCred configuration. Changes gh, the generated gitconfig, launchctl and
/// the env files, and ends on the profile that was active before.
/// Opt-in only, with the user's authorization: MULTICRED_REAL_SWITCH_REPRO=1
final class RealSwitchReproTests: XCTestCase {
    func testRealSwitchRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTICRED_REAL_SWITCH_REPRO"] == "1", "opt-in")
        let environment = RealEnvironment.make()
        let config = try XCTUnwrap(try ConfigRepository(environment: environment).load())
        let tools = ToolLocator(environment: environment)
        let engine = SwitchEngine(environment: environment, tools: tools, log: EventLog(directory: environment.logsDirectory))
        let start = try await engine.currentState()
        let path = await tools.searchDirectories()
        let env = environment.baseProcessEnvironment(path: path)
        let ghLocation = await tools.locate(.gh)
        let gitLocation = await tools.locate(.git)
        let gh = try XCTUnwrap(ghLocation)
        let gitBinary = try XCTUnwrap(gitLocation)

        func run(_ executable: URL, _ arguments: [String]) async -> String {
            let result = try? await ProcessRunner().run(CommandRequest(
                executable: executable, arguments: arguments, environment: env,
                currentDirectory: URL(fileURLWithPath: "/"), timeout: .seconds(30)
            ))
            let out = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return result?.succeeded == true ? out : "ERRO(\(result?.exitCode ?? -1)): \(err.prefix(200))"
        }

        func report(_ label: String) async {
            let active = await run(gh, ["config", "get", "-h", "github.com", "user"])
            let tokenOwner = await run(gh, ["api", "user", "--jq", ".login"])
            let email = await run(gitBinary, ["config", "--get", "user.email"])
            let launchd = await run(URL(fileURLWithPath: "/bin/launchctl"), ["getenv", "CLAUDE_CONFIG_DIR"])
            print("REPRO \(label): gh config=\(active) | gh api user=\(tokenOwner) | git email=\(email) | launchd=\(launchd.isEmpty ? "(unset)" : launchd)")
        }

        await report("inicio")
        let order = ["Trabalho", "Pessoal"].compactMap { name in config.profiles.first { $0.name == name } }
        XCTAssertEqual(order.count, 2, "profiles Trabalho and Pessoal must exist")
        for profile in order {
            do {
                let result = try await engine.switchProfile(profile.id, in: config)
                print("REPRO switch \(profile.name): steps=\(result.appliedSteps.map(\.rawValue))")
            } catch {
                print("REPRO switch \(profile.name) FALHOU: \(error)")
            }
            await report("depois de \(profile.name)")
        }
        // Back to where it started.
        if let original = start.profileId, original != order.last?.id {
            _ = try? await engine.switchProfile(original, in: config)
            await report("restaurado")
        }
    }
}
