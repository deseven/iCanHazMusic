import SwiftUI

/// Placeholder for the main window content (sidebar, playlist, playback block will live here).
struct MainWindow: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(AppConstants.appName)
                .font(.title2.weight(.semibold))
            Text("Nothing here yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
