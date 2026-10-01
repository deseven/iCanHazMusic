import SwiftUI

@main
struct PlaylistViewPoCApp: App {
    var body: some Scene {
        WindowGroup("Playlist view PoC") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 800, height: 700)
    }
}

struct ContentView: View {
    @State private var albumCount = 500
    @State private var playlist = FakeData.makePlaylist(albumCount: 500)
    @State private var generationMs = 0.0
    @State private var selection: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Albums", selection: $albumCount) {
                    ForEach([50, 200, 500, 1000, 3000], id: \.self) { Text("\($0) albums").tag($0) }
                }
                .fixedSize()

                Button("Select all") { selection = Set(playlist.rows.indices) }
                Button("Clear") { selection = [] }
                Spacer()
            }
            .padding(8)

            Divider()

            VirtualPlaylistView(playlist: playlist, selection: $selection)
                .id(ObjectIdentifier(playlist))   // fresh scroll state for a new playlist

            Divider()

            HStack {
                Text("\(playlist.albums.count) albums, \(playlist.trackCount) tracks (\(playlist.rows.count) rows)")
                Text("model built in \(generationMs, specifier: "%.1f") ms")
                Spacer()
                Text("selected: \(playlist.selectedAlbumCount(selection)) albums, \(playlist.selectedTrackCount(selection)) tracks")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(6)
        }
        .onChange(of: albumCount) { _, count in
            let p = makePlaylist(count)
            selection = []
            playlist = p
        }
        .onAppear { _ = makePlaylist(albumCount) }
    }

    private func makePlaylist(_ count: Int) -> Playlist {
        let start = DispatchTime.now()
        let p = FakeData.makePlaylist(albumCount: count)
        generationMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        return p
    }
}
