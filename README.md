# iCanHazMusic
A music player for macOS 15.4 or higher. The latest stable version can be downloaded on [the releases page](https://github.com/deseven/iCanHazMusic/releases), the latest unstable dev version is always available via [this link](https://d7.wtf/s/ichm-dev.zip) (use with caution!), see below for compiling from source.

Main app:  
![iCHM screenshot](https://d7.wtf/s/ichm.png)

## Features
- Fully native macOS app, built in Swift/SwiftUI/AppKit with no third-party dependencies
- Very low resource usage
- Playback of everything macOS can decode natively:
  - MP3, FLAC, AAC/M4A/M4B (including ALAC), Ogg Vorbis, WAV, AIFF/AIFC, CAF
  - not supported: Opus, WMA, APE, WavPack, MPC and other formats macOS can't open
- Gapless playback with its own audio engine (built on `AVAudioEngine`, exact seeking, high-quality resampling with configurable quality)
- Tags reading (ID3v1/v2, Vorbis comments, MP4, with recovery of truncated ID3v1 values), fast!
- Album art (embedded or external images in the album directory)
- Albums grouping with album art, or a flat list if you prefer (can be switched per playlist)
- Very large playlists (tens of thousands of entries at the very least)
- Playlists import/export (M3U8, M3U, PLS)
- Drag and drop of files, directories and playlists, recursive directory import
- Lyrics: embedded in tags or fetched from [LRCLIB](https://lrclib.net) (opt-in)
- Last.fm scrobbling and now playing updates
- System notifications about the playback
- Global hotkeys (media keys & custom ones) for playback, track/album navigation, random track/album and volume
- Dock menu with the current track and playback controls

## Why
I was a big fan of the legendary [foobar2000](https://www.foobar2000.org/) until I moved to macOS in 2010. Naturally, for some time I continued using foobar under Wine, but the experience was subpar and eventually I started jumping from player to player. Some notable examples in no particular order:
- [Clementine](https://www.clementine-player.org/) with its [many years old bug](https://github.com/clementine-player/Clementine/issues/4733) that makes it eat up to 50% of CPU for a simple mp3 playback
- [cmus](https://cmus.github.io/), which was fun and all, but just a bit too minimalistic
- [DeaDBeeF](https://deadbeef.sourceforge.io/) with no stable release and insane bugs (back when I was using it, things seems to have improved)
- [mac version of foobar2000](https://www.foobar2000.org/mac) which is a fucking joke of a player

I remember many other apps, both free and paid, however each and every one of them did lack something important. It's also worth mentioning that with every year the chance to get a decent desktop audio player is only getting lower and lower - it's an age of cloud music now, not many people are still interested in those mammoths of a bygone era. But the urge of having a good desktop player is still here for me, that's why I finally decided to go for it myself.

It's by no means a replacement for foobar2000, just my personal compilation of things I would like to see in an audio player. Nothing is set in stone, however, feel free to create new issues with feedback and suggestions.

## Roadmap
- playback queue
- queue, playback orders
- simple web interface and API
- playlist search
- playlist entries rearrangement
- better Last.fm integration (like tracks, track info, number of plays, etc)

#### What is not planned
- CUE support
- equalizer
- tags editing, format conversion and other Swiss knife functions
- advanced foobar2000-level customization

## Compiling from source
iCHM is a Swift package (Swift tools 5.10, no third-party dependencies) for macOS 15.4 or higher.

1. Install Xcode command line tools (`xcode-select --install`) with a Swift 5.10+ toolchain.
2. Clone the repo.
3. Run `./build.sh` to make a dev build: it builds the app for your architecture (arm64), creates `dist/iCanHazMusic.app` and launches it (it runs in the foreground until you quit the app).

Other modes:
- `./build.sh test` - generates test fixtures and runs the test suite, no artifacts.
- `./build.sh dev-release` - universal (arm64 + x86_64) build, tests, `dist/iCHM-dev.zip`, and uploads it with the `share` tool (specific to the author's setup, remove that step if you don't have it).
- `./build.sh release` - universal build, tests, `dist/iCHM.zip` and `dist/iCHM.dmg`.

The plain compile check is `swift build -c debug --arch arm64`.

Optional requirements:
- [FFmpeg](https://www.ffmpeg.org/) (`brew install ffmpeg`) for generating the test fixtures (`./build.sh test` and the release modes).
- [create-dmg](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`) for `release`.

Optional `.env` file in the repo root (git-ignored), read by `build.sh`:
- `ICHM_SIGNING_IDENTITY` - the codesigning identity (e.g. `Developer ID Application: ...`). Without it the app is signed ad-hoc, which is fine for running locally, but **system notifications won't work** in an ad-hoc signed build.
- `ICHM_NOTARY_PROFILE` (a `notarytool` keychain profile) or `ICHM_APPLE_ID` + `ICHM_TEAM_ID` + `ICHM_APP_PASSWORD` - notarization of the release builds.
- `ICHM_LASTFM_API_KEY` + `ICHM_LASTFM_API_SECRET` - your own [Last.fm API](https://www.last.fm/api/account/create) credentials. They are embedded (obfuscated) into the bundle's `Info.plist`; without them the Last.fm integration is disabled.

For now the app keeps its data (config, playlists, caches) in `~/Library/Application Support/iCanHazMusic-dev`; pass `--workdir /some/dir` to the app to use another directory.
