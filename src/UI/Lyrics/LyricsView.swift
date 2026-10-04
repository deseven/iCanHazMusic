import SwiftUI

/// Content of the lyrics sheet: artist and title, where the lyrics come from, the lyrics (scrolling). Synchronised
/// lyrics highlight the line that is being sung while the track is the one that plays.
struct LyricsView: View {
    enum Subject {
        /// Whatever plays: follows the player from track to track.
        case playing
        /// One track, whatever plays.
        case track(artist: String, title: String, album: String)
    }

    let subject: Subject
    let close: () -> Void

    private let player = PlaybackState.shared
    private let service = LyricsService.shared
    /// The lyrics of a `.track` subject, looked up once.
    @State private var stored: Lyrics?

    init(subject: Subject, close: @escaping () -> Void) {
        self.subject = subject
        self.close = close
        if case .track(let artist, let title, let album) = subject {
            _stored = State(initialValue: LyricsService.shared.lyrics(artist: artist, title: title, album: album))
        }
    }

    var body: some View {
        let shown = self.shown
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.heading)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let lyrics = shown.lyrics {
                    HStack(spacing: 6) {
                        SourceTag(text: lyrics.source.rawValue)
                        if lyrics.isSynced { SourceTag(text: "synced") }
                    }
                }
            }

            content(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Copy") { copy(shown.lyrics) }
                    .disabled(shown.lyrics == nil)
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: Layout.lyricsSheetWidth, height: Layout.lyricsSheetHeight)
    }

    /// The text without timestamps.
    private func copy(_ lyrics: Lyrics?) {
        guard let lyrics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lyrics.plain, forType: .string)
    }

    // MARK: What is shown

    private struct Shown {
        let heading: String
        let lyrics: Lyrics?
        /// The track is the one that plays (so a synchronised text can follow the music).
        let isPlaying: Bool
    }

    private var shown: Shown {
        switch subject {
        case .playing:
            let info = player.info
            return Shown(heading: info.map { "\($0.artist) – \($0.title)" } ?? "Nothing is playing",
                         lyrics: service.current, isPlaying: !player.isStopped)
        case .track(let artist, let title, let album):
            let key = LyricsKey.make(artist: artist, title: title, album: album)
            return Shown(heading: "\(artist) – \(title)", lyrics: stored,
                         isPlaying: !player.isStopped && key == service.currentKey)
        }
    }

    @ViewBuilder
    private func content(_ shown: Shown) -> some View {
        if let lyrics = shown.lyrics {
            if lyrics.isSynced {
                SyncedLyricsList(lyrics: lyrics, follows: shown.isPlaying, player: player)
            } else {
                ScrollView {
                    Text(lyrics.plain)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                }
            }
        } else {
            Text("No lyrics for this track.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The small rounded label under the title.
private struct SourceTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// The lines of synchronised lyrics. While `follows`, the line that is being sung is highlighted and kept in the
/// middle. The position is looked at 5 times a second (`PlaybackState.position` only moves in whole seconds), but
/// the view is only redrawn when the line changes.
private struct SyncedLyricsList: View {
    let lyrics: Lyrics
    let follows: Bool
    let player: PlaybackState

    @State private var active: Int?

    private struct FollowID: Hashable {
        let follows: Bool
        let lrc: String?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Empty lines at the start (an instrumental intro) are not shown, the others are a small gap.
                    ForEach(firstShown..<lyrics.lines.count, id: \.self) { index in
                        let line = lyrics.lines[index]
                        if line.text.isEmpty {
                            Color.clear.frame(height: 10).id(index)
                        } else {
                            Text(line.text)
                                .fontWeight(index == active ? .semibold : .regular)
                                .foregroundStyle(index == active ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, follows ? 200 : 4)                              // room to keep the last lines centered
                .padding(.trailing, 8)
            }
            .task(id: FollowID(follows: follows, lrc: lyrics.lrc)) { await follow() }
            .onChange(of: active) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }

    private var firstShown: Int {
        lyrics.lines.firstIndex { !$0.text.isEmpty } ?? 0
    }

    private func follow() async {
        active = nil
        guard follows else { return }
        while !Task.isCancelled {
            let line = lyrics.lineIndex(at: player.livePosition)
            if line != active { active = line }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
