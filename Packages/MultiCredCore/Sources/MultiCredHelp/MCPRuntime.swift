import Foundation
import MultiCredCore

/// Chooses which Mac the diagnostic looks at, always through read-only guards.
///
/// Release builds look at the real system. Debug builds look at the app's
/// test-mode sandbox (the same folder the Debug app uses) unless started with
/// `--real-system`, so developing never touches the real Mac.
public enum MCPRuntime {
    public static func makeDiagnosticService(arguments: [String] = CommandLine.arguments, guide: Guide = .bundled) -> DiagnosticService {
        let environment = makeEnvironment(arguments: arguments).readOnly()
        return DiagnosticService(
            environment: environment,
            tools: ToolLocator(environment: environment),
            // Outside the real system nothing real is observed, not even running processes.
            processes: environment.mode == .real ? SystemProcessScanner() : NoProcessScanner(),
            guide: guide
        )
    }

    static func makeEnvironment(arguments: [String]) -> SystemEnvironment {
        #if DEBUG
        if !arguments.contains("--real-system") {
            let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("multicred-sandbox", isDirectory: true)
            return RealEnvironment.makeDryRun(sandboxHome: sandbox.resolvingSymlinksInPath())
        }
        #endif
        return RealEnvironment.make()
    }
}

/// No running sessions: used when the diagnostic looks at the test sandbox.
struct NoProcessScanner: ProcessScanning {
    func claudeCodeSessionCount() -> Int { 0 }
}
