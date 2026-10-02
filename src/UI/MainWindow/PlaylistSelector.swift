import SwiftUI

/// The list of playlists. The one playback runs from is marked with a dot.
struct PlaylistSelector: View {
    private let store = PlaylistStore.shared

    var body: some View {
        List(store.names, id: \.self, selection: selection) { name in
            HStack(spacing: 6) {
                Label(name, systemImage: "music.note.list")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if name == store.playingName {
                    // Playback runs from this playlist (playing or paused). The selected row is filled with the
                    // accent color itself, so the dot is white there.
                    Circle()
                        .fill(name == store.activeName ? Color.white : Color.accentColor)
                        .frame(width: 8, height: 8)
                        .help("Playing from this playlist")
                }
            }
                .contextMenu {
                    Button("Rename") {
                        Task { await PlaylistActions.rename(name) }
                    }
                    Button("Delete") {
                        Task { await PlaylistActions.delete(name) }
                    }
                }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    Task { await PlaylistActions.create() }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New playlist")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { store.activeName },
            set: { if let name = $0 { store.setActive(name) } }
        )
    }
}
