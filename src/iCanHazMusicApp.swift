import SwiftUI

@main
struct iCanHazMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Single main window (the first scene is opened on launch).
        Window(AppConstants.appName, id: AppConstants.mainWindowID) {
            MainWindow()
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentMinSize)

        Window("About \(AppConstants.appName)", id: AppConstants.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)

        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commands {
            AppCommands()
        }
    }
}

/// Replaces the stock "About" item in the app menu with our own window.
private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppConstants.appName)") {
                openWindow(id: AppConstants.aboutWindowID)
            }
        }
    }
}
