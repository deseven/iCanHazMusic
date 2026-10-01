# iCanHazMusic – notes for coding agents
A native macOS music player (SwiftUI + AppKit, Swift package, no third-party dependencies).
Target: macOS 15.4+, Swift tools 5.10 (Swift 5 language mode).

## Layout
| Path | What |
|---|---|
| `src/` | The app (single SwiftPM executable target `iCanHazMusic`). |
| `PoC/` | Standalone proof-of-concepts, each with its own `build.sh`. Not part of the package. |
| `old-src/` | Legacy PureBasic version. Reference only, don't touch. |
| `build.sh` | Builds the `.app` bundle in `dist/` (see below). |
| `Info.plist`, `res/` | Bundle metadata and resources copied into the bundle by `build.sh`. |

`src/` is split into UI and logic (still one SwiftPM target, so no `public` needed):

| Folder | What |
|---|---|
| `src/App/` | `@main` entry point and `AppDelegate`. |
| `src/Core/` | Logic. **Foundation only: never import SwiftUI/AppKit here.** `Config/` (`Config.swift`, `ConfigStore.swift` for `config.json`, `ConfigLimits.swift` validation limits), `Playlists/` (`PlaylistStore.swift`, `playlists/*.json` plus the in-memory playlist content, which is not stored yet; `Playlist.swift` is the flattened album/track row model; `AlbumBuilder.swift` groups tag results into albums by directory + album tag), `Tags/` (tag reading via AudioToolbox/AVFoundation, album art detection; ported from `PoC/tag-parsing`, see its README; `TrailingTags.swift` recovers values that ID3v1 cut at 30 bytes from a Lyrics3v2/APEv2 block at the end of v1-only MP3s), `Import/` (`AudioFileGatherer` = supported extensions, recursive walk, dedupe, natural sort; `ImportSession` = gather -> read tags -> build albums, publishes progress, supports abort), `Playback/` (`PlaybackState.swift`), `Constants.swift`, `Log.swift`, `StableHash.swift`. |
| `src/UI/` | Views and AppKit glue. `Layout.swift` (layout constants), `MainWindow/`, `Playback/`, `Playlist/` (virtualised playlist view: `VirtualPlaylistView`, `PlaylistLayout` row offsets, row views, `CoverCache`), `About/`, `Dialogs/` (`Dialogs.swift` + `PlaylistActions.swift`, NSAlert-based flows), `Window/` (`WindowPersistence.swift`, `WindowAccessor.swift`), `Import/` (`ImportCoordinator` = File menu / drag and drop entry points, `ImportProgressSheet` + `ImportProgressView` = the modal progress sheet). |

UI may depend on Core, never the other way round. One view per file.

## Runtime data
Everything lives in `~/Library/Application Support/iCanHazMusic-dev` (hardcoded in `AppPaths`, see `Constants.swift`):

- `config.json` – read once at startup, written on every setting change (debounced ~250 ms, flushed on quit).
  Missing/invalid values are reset to defaults and written back.
- `playlists/{name}.json` – one file per playlist; `main.json` is created automatically if there are none.

This is the user's real dev data. When testing, prefer seeding/inspecting the files over deleting them, and
leave the directory in a sane state afterwards.

## Building and running
- Full dev build + launch: `./build.sh` (clean build, ad-hoc signing, then **runs the app in the foreground**).
  It blocks until the app quits, so give it a `timeout_ms` or don't use it from an agent; the user normally runs it.
- Compile check only: `swift build -c debug --arch arm64`.
- Fast typecheck without SwiftPM:
  `swiftc -typecheck -parse-as-library -target arm64-apple-macos15.4 $(find src -name '*.swift')`
  (src is now nested, so a plain `src/*.swift` glob no longer matches; list the files explicitly with `find`.)
- There is no test target. Logic that doesn't need UI can be exercised with a throwaway `main.swift` compiled
  together with the needed `src/**/*.swift` files (everything except `App/iCanHazMusicApp.swift`, which has `@main`).
  Put such scratch files in `tmp/` (git-ignored; never use `dist/`, `build.sh` wipes it) and delete them afterwards.

### Quirks worth knowing
- SwiftUI does not honor the sidebar's ideal width (it always starts at 140). Don't fight it; the width is saved
  but not forced.
- SwiftUI re-places the window after the view is attached, so `WindowPersistence` applies the saved frame twice
  (immediately and on the next run-loop turn) and starts observing changes only after that.
- The saved window size is the whole frame (title bar/toolbar included), not the content size.
- Killing the app with SIGKILL (e.g. a command timeout) can lose the last ≤250 ms of config changes; SIGTERM is fine.

## Conventions
- Keep config validation limits in `ConfigLimits.swift` (config values outside them are reset to defaults) and
  layout constants in `Layout.swift`; `Layout` derives shared values from `ConfigLimits`.
- Change settings only through `ConfigStore.shared.update { ... }`; don't write `config.json` elsewhere.
- Playlist name rules and file operations live in `PlaylistStore`; UI flows (prompt, confirm, error) in `PlaylistActions`.
- Use `Log.info` / `Log.error` (stdout, `[iCHM]` prefix) rather than bare `print`.
- Dialogs are `NSAlert` sheets on the main window (`Dialogs`), not SwiftUI alerts.
