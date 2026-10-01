import SwiftUI

struct PlaylistSelector: View {
    private let store = PlaylistStore.shared

    var body: some View {
        List(store.names, id: \.self, selection: selection) { name in
            Label(name, systemImage: "music.note.list")
                .lineLimit(1)
                .truncationMode(.tail)
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
