import SwiftUI

@main
struct MultiCredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar app: windows are opened on demand by AppDelegate.
        Settings { EmptyView() }
    }
}
