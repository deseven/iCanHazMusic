# Lyrics

Embedded lyrics from the file are the source of truth, LRCLIB (off by default) the fallback. Research notes of 2026-10-04 and how it is implemented (`src/Core/Lyrics/`, `src/Core/Integrations/LRCLIB/`, `src/UI/Lyrics/`).

## How it works

- **Storage**: `.cache/lyrics.sqlite` (`LyricsStore`), one row per `LyricsKey` (SHA-256 of lower-cased, trimmed artist + title + album): source (`embedded`/`lrclib`), plain text, synced LRC text if any. Safe to delete: LRCLIB lyrics are fetched again on the next play, embedded ones come back with Reload Tag(s).
- **Embedded**: the tag reader returns the lyrics of the file (`TrackTags.lyrics`), `ImportSession` stores them under the key of the track as it will be in the playlist (so Reload Tag(s) refreshes them) and replaces whatever is there. Files without artist/title tags are skipped. Nothing reads lyrics from files at play time, so tracks imported before this feature need Reload Tag(s) once.
- **Playing**: `LyricsService` (a `PlaybackListener`) looks the track up in the store when it starts. If there are none and LRCLIB is on, it asks LRCLIB once (queue: one at a time, 10 tries with 1/2/4/... s backoff, `Retry-After` honored, 300 ms between lookups, newest wins). Found lyrics are stored (never over embedded ones) and shown right away. A "no answer" is remembered until the app quits; a failed lookup is tried again at the next play. Tracks without tags ("Unknown Artist"/"Unknown Track") are never looked up.
- **Matching**: `/api/search` by artist + title (one request; `/api/get` only accepts +-2 s of duration and found less, see below), then locally: artist and title **exactly** equal (case and blank space ignored, diacritics and "feat."/"- Topic" suffixes are not), duration within 10%, has lyrics, not an instrumental. Of those: synced first, then same album, then nearest duration.
- **UI**: a button in the playback block while the playing track has lyrics; "Lyrics..." in the context menu of a single track that has them. Both open a sheet: artist - title, a tag with the source, the text. Synced lyrics (LRCLIB; an LRC text in a file's lyrics tag too) highlight the line being sung.
- Every request of the app carries `User-Agent: iCanHazMusic/{version}`.

## Embedded lyrics

Checked on macOS 26 with generated files (`tests/prepare-fixtures.sh`, `l*` files) and by hand-made ID3 tags:

| Container | Tag | AudioToolbox | AVFoundation |
|---|---|---|---|
| MP3 ID3v2.3/2.4 | `USLT` | no | `id3/USLT`, `stringValue` = the text (language and descriptor are dropped; every text encoding works) |
| MP3 ID3v2.2 | `ULT` | no | bare key `ULT` (`identifier == nil`) |
| MP3 ID3v2 | `SYLT` (synced) | no | binary only (`stringValue == nil`); **not read** |
| FLAC, Ogg Vorbis | `LYRICS`, `UNSYNCEDLYRICS` | no | `vorb/LYRICS`, `vorb/UNSYNCEDLYRICS` |
| MP4/M4A (AAC, ALAC) | `©lyr` | no | `itsk/%A9lyr` |
| CAF | `lyrics` | info dictionary key `lyrics` | `caaf/info-lyrics` |
| WAV, AIFF | - | no | no |
| APE tags, Lyrics3v2 `LYR` | - | no | no; **not read** (`TrailingTags` only walks them for ID3v1 values) |

- AudioToolbox lists lyrics for CAF only, so for every other file a pass of its own is needed: **FLAC by hand** (the Vorbis comment block is read directly, as for pictures, cheap), everything else through AVFoundation (only if the normal read didn't go through it already: MP3 does, the rest of the formats doesn't, which makes reading M4A/Ogg/WAV files slower).
- ffmpeg can't write a `USLT` frame (`-metadata lyrics=` ends up in a `TXXX` frame), the MP3 fixture is built by hand in `prepare-fixtures.sh`.
- A lyrics tag that holds an LRC text (two or more `[mm:ss.xx]` lines) is treated as synced lyrics.

## LRCLIB

Docs: https://lrclib.net/docs (checked 2026-10-04). Source: https://github.com/tranxuanthang/lrclib.

- **No API key.** Base URL `https://lrclib.net/api`.
- **`User-Agent` is required**: app name, version and a link, e.g. `iCanHazMusic/1.0 (https://github.com/deseven/iCanHazMusic)`.
- **Rate limiting**: `429` with a `Retry-After` header (seconds) that the client **must** honor, otherwise a temporary ban. Send requests **one at a time** and add a 200-500 ms delay between them (batch operations especially).
- `GET /api/get?track_name=&artist_name=&album_name=&duration=`: best match for the track. `track_name` and `artist_name` are required, `album_name` and `duration` (seconds, 1-3600) recommended. The record is returned only if its duration is within **+-2 s** of the given one. `404` = not found ("missing tracks can be picked up by the background lyrics fetching service and may become available in a later request").
- `GET /api/get/:id`: by LRCLIB's ID.
- `GET /api/search?q=` or `?track_name=&artist_name=&album_name=`: at most 20 records, no pagination, `track_name` or `q` required.
- Response record: `id`, `trackName`, `artistName`, `albumName`, `duration`, `instrumental`, `plainLyrics`, `syncedLyrics` (LRC, `[mm:ss.xx]` per line), `lyricsfile` (YAML with per-line `start_ms`/`end_ms`, always present); `hasWordSync` has been seen too (undocumented).
- Publishing/flagging (`POST /api/publish`, `/api/flag`) needs a proof-of-work token (`POST /api/request-challenge`).
- **Caveats**: no terms of service or data licence found; the lyrics are user-contributed copyrighted text with no sign of publisher licensing (there is a flag for copyright violations). The service explicitly invites client apps. Whether caching is allowed is not stated. Coverage depends on the community. The service can disappear or change.

## How good is the database

Test on 2026-10-04: five obscure artists from the user's library (every track, 134 in total). Tags and durations from the files via `ffprobe`; `/api/get` with artist, title, album and rounded duration, and on a miss `/api/search` by artist + title (counted as found when the closest hit has non-empty `plainLyrics` and a duration within 8 s). "Found" does **not** mean verified correct, the texts were not compared with the songs.

| Artist | Tracks | `/api/get` | only via `/api/search` | Found |
|---|---|---|---|---|
| Euzen | 32 | 27 | 4 | **31 (97%)** |
| KorovaKill | 34 | 19 | 2 | **21 (62%)** |
| Dandi Wind | 38 | 1 | 2 | **3 (8%)** |
| Ştiu Nu Ştiu | 8 | 0 | 0 | **0** |
| Costa Gravos | 22 | 0 | 0 | **0** |
| **All** | **134** | 47 (35%) | 8 | **55 (41%)** |

Findings:

- Coverage varies wildly per artist. Ştiu Nu Ştiu and Costa Gravos do have vocals but most likely never had their lyrics published anywhere, so these are real gaps, not tagging problems.
- Only 4 of the 55 hits had `syncedLyrics`.
- **`/api/get` alone is not enough**: 8 tracks were only found by the search fallback (names differ slightly: the database has `Korova` for `KorovaKill`, `Sálømeh, des Teufels Braut` for `Salomeh, Des Teufels Braut`, or the album/duration doesn't match exactly, while search found the very same record).
- **Results change over time**: a second run a few minutes after the first found more (Euzen 23 -> 27 exact hits, some earlier misses turned into hits). Probably the background fetching mentioned in the docs. A miss is not final.
