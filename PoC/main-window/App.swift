import SwiftUI

/// A bare executable (not launched from an .app bundle) starts with a non-regular activation
/// policy: the window shows up, but the app isn't properly active, so hover / cursor
/// changes / tracking areas don't work reliably. Make it a regular app and activate it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

@main
struct MainWindowPoCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("iCanHazMusic") {
            MainWindow()
                .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
                .onAppear {
                    // Once the window exists: be a regular app and bring it to front.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
        }
        .defaultSize(width: Layout.windowMinWidth, height: Layout.windowMinHeight)
        .windowResizability(.contentMinSize)
    }
}
