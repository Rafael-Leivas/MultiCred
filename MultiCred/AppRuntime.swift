import Foundation
import MultiCredCore

/// Chooses which system the app talks to.
///
/// Debug builds start in test mode: a sandbox home in the temporary directory,
/// commands recorded instead of executed, and an in-memory keychain. The real
/// system is used only when launched with `-MultiCredRealSystem YES`.
/// Release builds always use the real system.
enum AppRuntime {
    static let realSystemArgument = "MultiCredRealSystem"

    static func makeEnvironment() -> SystemEnvironment {
        #if DEBUG
        // Launch arguments only, never persisted defaults: a forgotten
        // `defaults write` must not silently switch a debug build to the real system.
        if launchArgumentIsYes(realSystemArgument) {
            return RealEnvironment.make()
        }
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multicred-sandbox", isDirectory: true)
        return RealEnvironment.makeDryRun(sandboxHome: sandbox)
        #else
        return RealEnvironment.make()
        #endif
    }

    private static func launchArgumentIsYes(_ name: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-" + name), index + 1 < arguments.count else { return false }
        return ["YES", "yes", "1", "true"].contains(arguments[index + 1])
    }
}
