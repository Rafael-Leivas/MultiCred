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
        if UserDefaults.standard.bool(forKey: realSystemArgument) {
            return RealEnvironment.make()
        }
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multicred-sandbox", isDirectory: true)
        return RealEnvironment.makeDryRun(sandboxHome: sandbox)
        #else
        return RealEnvironment.make()
        #endif
    }
}
