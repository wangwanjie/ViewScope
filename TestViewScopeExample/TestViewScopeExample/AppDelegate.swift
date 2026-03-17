import Cocoa
#if DEBUG
import ViewScopeServer
#endif

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ViewScopeInspector.start(
            configuration: .init(displayName: "TestViewScopeExample")
        )
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
