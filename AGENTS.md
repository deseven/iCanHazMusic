# iCanHazMusic – notes for coding agents
A native macOS music player (SwiftUI + AppKit, Swift package, no third-party dependencies).
Target: macOS 15.4+, Swift tools 5.10 (Swift 5 language mode).

## Layout
| Path | What |
|---|---|
| `src/` | The app (single SwiftPM executable target `iCanHazMusic`). |
| `tests/` | Swift Testing suite (`swift test`), see [Tests](#tests) below. |
| `docs/` | Background notes: `tag-parsing.md` = what the macOS tag APIs do and why the reader is built the way it is; `playback.md` = why `AVAudioEngine` and not `AVPlayer` (AVFoundation's FLAC seeking/padding bugs), how the engine works, API quirks. |
| `old-src/` | Legacy PureBasic version. Reference only, don't touch. |
| `build.sh` | Builds the `.app` bundle in `dist/` (see [Building and running](#building-and-running)). |
| `Info.plist`, `res/` | Bundle metadata and resources copied into the bundle by `build.sh`. |

### `src/`
Split into UI and logic (still one SwiftPM target, so no `public` needed). UI may depend on Core, never the other way round. One view per file.

- `App/` – `@main` entry point, `AppDelegate` and `DockMenu` (the Dock icon's right-click menu: current track and transport commands, only shown while playing/paused, like in the old version; built fresh on every open).
- `Core/` – Logic. **Foundation only (plus system frameworks without UI such as CryptoKit): never import SwiftUI/AppKit here.** Things that need AppKit (opening URLs, alerts) are handed in by the UI as closures.
  - `Integrations/LastFM/` – the last.fm integration (API docs: https://www.last.fm/api/authspec). Credentials are **not in the sources**: `build.sh` writes `ICHM_LASTFM_API_KEY`/`ICHM_LASTFM_API_SECRET` from `.env` into the bundle's `Info.plist` (`ICHMLastFMAPIKey`/`ICHMLastFMAPISecret`), XOR-ed with `LastFMCredentials.obfuscationKey` and base64-encoded (obfuscation only, so they can't be read at a glance; `build.sh` reads the key from that line of `LastFMAPI.swift`, keep its format), `LastFMCredentials.bundled` reads and decodes them; without them (plain `swift build`) the integration is unavailable (Connect is disabled). Never put them into sources or tests (tests use dummy ones).
    - `LastFMAPI.swift` – credentials, `LastFMCall`, signing, request building, answer checking and the **error classification** (`LastFMError.Kind`: `authentication` = codes 4/9/10/17/26 -> disconnect; `temporary` = 8/11/16/29, 5xx, network, garbage -> retry; `rejected` = anything else -> drop that call).
    - `LastFMClient.swift` – `LastFMTransport` (`URLSessionTransport`: 30 s hard limit; tests use a stub) and the client.
    - `LastFMQueue.swift` – one call at a time, in order, up to 10 tries with 1/2/4/... s backoff; pending now playing updates behind the head are replaced by newer ones; in memory only.
    - `LastFMAuth.swift` – token -> open the confirmation URL -> `getSession` every 5 s and on `checkNow()` (the app becoming active); error 14 = not confirmed yet.
    - `LastFMService.swift` – `LastFMService.shared`: connection state (config `integrations.lastfm.session`/`username`), connect/disconnect, and the `PlaybackListener` that enqueues now playing (track start) and scrobbles (track left after >= 50% listened, track >= 30 s). `onConnectionLost` is called after Last.fm refused the session (the service has disconnected itself by then; the UI alerts and bounces the Dock icon).
  - `Config/`
    - `Config.swift`
    - `ConfigStore.swift` – `config.json`.
    - `ConfigLimits.swift` – validation limits.
  - `Playlists/`
    - `PlaylistStore.swift` – playlist list + the one active playlist, which is loaded async when activated, unloaded on switch/delete and saved in the background after changes. It also does the edits that replace the active content: `remove(ids:)`, `applyTags` (reloaded tags), `setFlat`, plus `updateTrack(id:…)` (duration/format pushed from playback), all telling `PlaybackState.playlistWasReplaced` so the playing track is found again by its ID. It keeps each loaded playlist's `last_played` (`setLastPlayed`, called by playback whenever a track starts; `lastPlayedRow`; saves are coalesced) outside the immutable `Playlist`, and counts `openCount` (a playlist became active with its content in place), which the UI reacts to by selecting and scrolling to the last played row.
    - `PlaylistFile.swift` – file format.
    - `TrackEntry.swift` – one flat stored track, and `TrackID`.
      - **Track IDs**: every track has a positive number unique within its playlist, stable through regrouping, removals, tag reloads and playback updates, never reused (`next_id`). The same file added twice = two IDs. `Playlist` hands them out itself (an import's tracks come in with `unassignedTrackID`; missing/duplicate IDs in a file are repaired on load) and looks tracks up by them (`position(of:)`, `row(of:)`, `track(id:)`). Refer to tracks by ID wherever a reference has to outlive a playlist edit; `(album, track)` positions (`TrackPosition`) and row numbers are only valid for one `Playlist` instance.
    - `Playlist.swift` – the flattened album/track row model.
    - `PlaylistExchange.swift` – `PlaylistFormat` (`m3u8`/`m3u`/`pls`) and reading/writing those files. Export writes absolute paths, UTF-8, with titles/durations. Import takes **only the paths** (playlist order, deduped, non-local and unsupported-extension entries dropped, missing files kept so the tag reader reports them as failed); tags in the file are ignored and re-read. `ImportSession.run(playlists:)` builds one album per track to keep the order.
    - `AlbumBuilder.swift` – groups flat entries into albums by directory + album tag, for imports and loads alike. With `flat: true` every track is an album of its own: a *flat* playlist has no header rows, but positions/playback still work on `(album, track)`.
    - `AlbumKey` – that identity as a string, also the cover cache key.
  - `Artwork/`
    - `AlbumArtProcessor` – per album: pick the source by the `ArtworkSource` priority, extract the image bytes once, shrink, cache.
    - `Thumbnailer` – ImageIO resize to a square `AppConstants.coverThumbnailPixels` JPEG/PNG.
    - `CoverStore` – SQLite cache `.cache/covers.sqlite`, key -> image bytes.
  - `Tags/` – tag reading via AudioToolbox/AVFoundation, album art detection; see `docs/tag-parsing.md`.
    - `TrailingTags.swift` – recovers values that ID3v1 cut at 30 bytes from a Lyrics3v2/APEv2 block at the end of v1-only MP3s.
  - `Import/`
    - `AudioFileGatherer` – supported extensions, recursive walk, dedupe, natural sort.
    - `ImportSession` – gather -> read tags -> build albums, publishes progress, supports abort (`reload(files:)` = the same for files already in the playlist). As soon as all files of a directory are read, its albums' art is processed concurrently with the remaining reads.
  - `Playback/` – see `docs/playback.md` for why it is not `AVPlayer`.
    - `PlaybackEngine` – gapless playback of a current + next track through one `AVAudioPlayerNode`, with fades, exact position, offline rendering for tests.
    - `TrackDecoder` – one file -> stereo float32 chunks at the output rate (own queue, exact length, seeking, resampling).
    - `ChannelDownmix`
    - `PlaybackListener.swift` – `PlaybackListener` (told by `PlaybackState` when a track starts/ends, with the time actually listened to: `PlayProgress`, forward seeks and pauses don't count; `LastFMService` is the listener), `PlayedTrack`.
    - `ResampleQuality` – `low`/`medium`/`high`/`max` (config `playback.resample_quality`, default `high`); `PlaybackState.resampleQuality` hands it to `PlaybackEngine.resampleQuality`, which gives it to each new `TrackDecoder` (so it applies to tracks opened afterwards).
    - `CodecLabel` – format description such as `MP3 CBR 320k` / `FLAC 24/96` from the opened file, which playback writes back to the playlist together with the real duration.
    - `PlaybackState` – playlist logic and what the playback block shows, on top of the engine. Also `playingRow` (play symbol) and the Playback menu options `cursorFollowsPlayback`/`playbackFollowsCursor` (config `playback.*`; the UI reports the cursor row via `cursorRow`, which may be in another playlist than the playing one: playback then moves over to it when that track starts).
  - `Constants.swift`, `Log.swift`, `StableHash.swift`
- `UI/` – Views and AppKit glue.
  - `Layout.swift` – layout constants.
  - `MainWindow/`, `Playback/`, `About/`
  - `Preferences/` – `PreferencesView`, the Preferences window (⌘,, a `Window` scene): vertical tabs General / Playback / Playlist / Integrations / Hotkeys (General and Hotkeys are empty so far; Integrations has the Last.fm Connect/Disconnect block). `LastFMActions` = the UI flows (confirmation sheet `LastFMAuthSheet` + alerts on the Preferences window, `connectionLost` alert + Dock bounce). Controls bind straight to the setting's owner (`PlaybackState.resampleQuality`, `PlaylistStore.tagParsingConcurrency`/`displayAlbumArt`), which persists it via `ConfigStore`.
  - `Playlist/` – virtualised playlist view: `VirtualPlaylistView`, `PlaylistLayout` (row offsets), row views, `CoverCache` (cached thumbnail from `CoverStore` or generated placeholder). The row context menu/keys (Play, Reveal in Finder, Reload Tag(s) = ⌘R behind the import sheet, Remove from Playlist = Backspace) live in `VirtualPlaylistView` + `PlaylistItemActions`.
  - `Dialogs/` – `Dialogs.swift` + `PlaylistActions.swift`, NSAlert-based flows (`PlaylistActions.exportActive` = the Playlist menu's Export, an `NSSavePanel` with a format popup).
  - `Window/` – `WindowPersistence.swift`, `WindowAccessor.swift`.
  - `Import/` – `ImportCoordinator` (File menu / drag and drop entry points), Playlist > Import playlist...; **drops: playlist files are imported only if nothing but playlist files was dropped, in a mix with audio files/directories they are ignored (albums often carry their own playlist); File > Add File(s)/Directory never import playlists**, `ImportProgressSheet` + `ImportProgressView` (the modal progress sheet).

## Runtime data
Everything lives in `~/Library/Application Support/iCanHazMusic-dev` (`AppPaths`, see `Constants.swift`). Pass `--workdir /some/dir` (or `--workdir=/some/dir`) to the app to use another directory instead, e.g. a scratch copy:
- `config.json` – read once at startup, written on every setting change (debounced ~250 ms, flushed on quit). Missing/invalid values are reset to defaults and written back.
  - `integrations.lastfm.session` / `username` (empty = not connected; one without the other is reset): the Last.fm session key and account name. Removed on disconnect.
  - `playback.volume` (0...1, default 0.7): the volume slider's value, restored on startup.
  - Preferences: `playback.resample_quality` (`low`/`medium`/`high`/`max`), `playlist.tag_parsing_concurrency` (`0` = auto = number of physical cores, else one of `ConfigLimits.tagParsingConcurrencyOptions`; read when an import starts), `playlist.display_album_art` (off: grouped playlists show no covers and load none, the album headers get shorter; art is cached on import regardless).
- `.cache/covers.sqlite` – album art thumbnails (key = `AlbumKey`, value = JPEG/PNG bytes, 2x the album block cover), rebuilt on import, safe to delete. The thumbnail size is stored in `PRAGMA user_version`; a different size drops the table.
- `playlists/{name}.json` – one file per playlist; `main.json` is created automatically if there are none.
  - Format: `{"version": 1, "is_flat": false, "next_id": N, "last_played"?: id, "tracks": [{id, path, artist, album, title, trackNumber?, year?, duration?, codec}, ...]}`, a flat array in playlist order (albums are rebuilt on load, album art isn't stored).
  - `id` / `next_id`: see Track IDs above; files from before IDs existed get them on load.
  - `last_played`: ID of the track that was started last; ignored if the playlist has no such track. Opening a playlist selects it and scrolls to it (`PlayerArea.playlistOpened`, `PlaybackState.placeCursor` puts the cursor there without that being a request for `playbackFollowsCursor`).
  - `is_flat` (missing = false) is the Playlist menu's "Don't group by albums": no album blocks, `artist – title` rows, no track numbers.
  - `duration` and `codec` are corrected by playback when the opened file says otherwise.
  - A file that can't be parsed is moved to `{name}.json.broken` and replaced by an empty playlist.

This is the user's real dev data. When testing, prefer seeding/inspecting the files over deleting them, and leave the directory in a sane state afterwards.

## Building and running
- Full dev build + launch: `./build.sh` (clean build, ad-hoc signing, then **runs the app in the foreground**). It blocks until the app quits, so give it a `timeout_ms` or don't use it from an agent; the user normally runs it.
- Compile check only: `swift build -c debug --arch arm64`.
- Fast typecheck without SwiftPM: `swiftc -typecheck -parse-as-library -target arm64-apple-macos15.4 $(find src -name '*.swift')`. `src/` is nested, so a plain `src/*.swift` glob doesn't match; list the files explicitly with `find`.
- Tests only: `./build.sh test` (generates the fixtures, then `swift test`; no artifacts). `dev-release` and `release` run the same two steps after the build and abort on a failure; plain `./build.sh` (dev) skips them.
- Scratch experiments go to `tmp/` (git-ignored; never use `dist/`, `build.sh` wipes it); delete them afterwards.

## Tests
`swift test` runs the Swift Testing suite in `tests/` (`@testable import iCanHazMusic`). All suites are nested in `AllTests` and run serialized on the main actor; mark new suites `@MainActor @Suite(...)` inside `extension AllTests`.

- Audio/image fixtures are generated, not committed: run `./tests/prepare-fixtures.sh` once (needs `ffmpeg`, `brew install ffmpeg`; it exits with an error if it is missing). Output goes to `tests/fixtures/generated/` (git-ignored). Tests using them fail with a hint if they weren't generated. Every tagged fixture carries the values in `Fixtures` (`TTitle`/`TArtist`/`TAlbum`/2020/track 3, 2 seconds long); add new fixtures to the script and document them there.
- Tests never touch the real working directory: `ConfigStore(paths:)`, `PlaylistStore(paths:configStore:)`, `CoverStore(url:thumbnailPixels:)` and `ImportSession(coverStore:)` take their locations as parameters, tests use `TempDir` (`tests/Support/Fixtures.swift`). Don't touch `.shared` singletons from tests.
- Playback tests run the engine **offline** (`PlaybackEngine(output: .offline(sampleRate:))`, driven by `EngineRig` in `tests/Support`): the output is compared sample by sample with the generated ramp/tone fixtures (`RampFile`/`ToneFile` in `PlaybackSupport.swift`, files `playback/*` made by `prepare-fixtures.sh`). `PlaybackState(store:engine:tickInterval:)` takes its store and engine as parameters; use `tickInterval: nil` and call `tick()` yourself. Mind the app's default volume of 0.7 when comparing samples.
- Not covered: the real output device (start/stop, device changes; see `docs/playback.md`) and the SwiftUI/AppKit layer.

### Quirks worth knowing
- A **crash** in the test process (a failed `precondition`, a force-unwrapped nil, an ObjC exception) looks like a **hang** of `swift test`: the Swift backtracer symbolicates for minutes. Run with `SWIFT_BACKTRACE=enable=no` to fail fast, and wrap long runs in `timeout`. Test helpers should report problems with `#expect`/return values, not trap.
- SwiftUI does not honor the sidebar's ideal width (it always starts at 140). Don't fight it; the width is saved but not forced.
- SwiftUI re-places the window after the view is attached, so `WindowPersistence` applies the saved frame twice (immediately and on the next run-loop turn) and starts observing changes only after that.
- The saved window size is the whole frame (title bar/toolbar included), not the content size.
- Killing the app with SIGKILL (e.g. a command timeout) can lose the last ≤250 ms of config changes; SIGTERM is fine.

## Rules & Conventions
- Keep config validation limits in `ConfigLimits.swift` (config values outside them are reset to defaults) and layout constants in `Layout.swift`; `Layout` derives shared values from `ConfigLimits`.
- Change settings only through `ConfigStore.shared.update { ... }`; don't write `config.json` elsewhere.
- Playlist name rules and file operations live in `PlaylistStore`; UI flows (prompt, confirm, error) in `PlaylistActions`.
- Use `Log.info` / `Log.error` (stdout, `[iCHM]` prefix) rather than bare `print`.
- Dialogs are `NSAlert` sheets on the main window (`Dialogs`), not SwiftUI alerts.
- Log whatever seems important but not overly noisy.
- There should be no compilation warnings. If you see one, fix it even if it's not from the recent changes.
- Prefer the included tools for reading, writing and editing the files.
