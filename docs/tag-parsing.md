# Tag parsing notes

Findings from the original tag-parsing proof of concept (since removed; the code lives in `src/Core/Tags/`).
They explain *why* the reader looks the way it does. Behaviour described here is covered by `tests/`
(fixtures from `tests/prepare-fixtures.sh`).

## Findings

1. **No subprocess needed.** `AudioToolbox` (`AudioFileOpenURL` + `kAudioFilePropertyInfoDictionary`) and
   `AVFoundation` (`AVURLAsset` metadata) read the tags of every container we support (WAV, AIFF, CAF, MP3,
   AAC/M4A, ALAC, FLAC, OGG Vorbis). WMA/APE/WavPack/MPC are readable by neither. Spotlight (`MDItem`) is
   useless (file name as title, no artist/album). An `ffprobe` per file was ~2x slower and drags in a binary.
2. **Per-format routing (`TagReader.Strategy.auto`).** On a NAS, AVFoundation is ~2x faster than AudioFile for
   MP3, AudioFile is ~1.4x faster for FLAC. So `.mp3` goes to AVFoundation, everything else to AudioFile; the
   other backend is consulted only if the artist is still missing.
3. **Concurrency pays off on a network share** (1 -> 16 parallel: ~30 -> ~160 files/s) and saturates at ~16.
   `TagReader.defaultConcurrency` is the number of physical cores; `ImportSession` passes 16.
4. **Both APIs read ID3v1.** AVFoundation exposes no metadata formats for ID3v1-only files, AudioFile does.
5. **ID3v2.2 is a trap.** AVFoundation exposes its 3-char frames (`TT2`, `TP1`, ...) with `identifier == nil`
   and only a bare `key`; a reader that requires `identifier` silently reports "no tags" for those files.
6. **`AVAsset.duration` is wrong for some OGG files** (535 s instead of 232.6 s) while AudioFile's
   "approximate duration" matches. Prefer AudioFile for duration where accuracy matters.
7. **ID3v1 cuts values at 30 bytes.** Old files tagged with ID3v1 only often carry the full values in a
   Lyrics3v2 or APEv2 block right before it; see `TrailingTags`.
8. **APEv2 + ID3v1 without ID3v2 confuses AVFoundation**: it finds the `TAG` inside `APETAGEX` and returns
   garbage fields (shifted by a few bytes) instead of the v1 values, while AudioFile reads them correctly.
   `TagReader` detects that layout (`TrailingTags.hasApeBeforeV1`) and reads such files with AudioFile only.
9. **FLAC pictures are invisible** to both APIs (AudioFile claims the property exists but returns nothing), so
   `FlacArtwork` walks the metadata block headers by hand.

## What each API sees

Samples tagged with title/artist/album/year/track (macOS 26):

| Container | AudioToolbox `InfoDictionary` | AVFoundation metadata | Notes |
|---|---|---|---|
| MP3 (ID3v2.3/2.4) | title, artist, album, year, track | all items incl. custom | both also read ID3v1 |
| MP3 (ID3v2.2) | title, artist, album, year, track | bare keys, **`identifier` is nil** | see above |
| MP3 (ID3v1 only) | title, artist, album, year, track | - | |
| AAC / ALAC / M4A | complete | complete (`itsk`) | atom keys start with the Latin-1 byte `0xA9` ("(c)") |
| FLAC | complete | complete (`vorb/*`) | duration slightly off |
| OGG Vorbis | complete | complete (`vorb/*`) | **duration can be very wrong** |
| WAV | title, artist | title, artist (`caaf/info-*`) | ffmpeg writes no album/year/track here |
| AIFF | title (+ffmpeg's minimal set) | same | |
| CAF | complete | same | |

## Error classification

AudioToolbox returns an undocumented `'wht?'` (2003334207) for a path that does not exist, AVFoundation a
generic "operation could not be completed". So the reason is classified *after* a read has failed
(`TagReader.explainFailure`): file not found / not a file / empty / unrecognised header, else the backend's own
message. A vanished file is reported, never silently dropped.

## Artwork

Detection never decodes an image; priority (first hit wins): folder image `cover|folder|album|front` +
`jpg|jpeg|png` (cover > folder > album > front, then jpg > jpeg > png), then embedded art, then any other image in
the folder. Embedded art is detected through AVFoundation item keys (`APIC`/`PIC`, `covr`, common-key artwork,
Vorbis `METADATA_BLOCK_PICTURE`), for FLAC through `FlacArtwork`. Folders are listed once per directory
(`ArtworkDirectoryCache`), hidden `._cover.jpg` AppleDouble leftovers are ignored.

## Limitations / open questions

- **OGG Opus / `.oga`**: tags are readable and `AVAudioPlayer` opens `.opus`, but `prepareToPlay()` fails for
  Opus on macOS 26. Both extensions are excluded from `AudioFileGatherer.supportedExtensions`.
- WMA/APE/WavPack/MPC need a bundled decoder if ever required.
- `discogs_artist_list` only exists as an ID3 `TXXX` frame (private key in AVFoundation); it is in the artist
  fallback chain but rarely hits.
- Track/disc "N/M" is reduced to the leading integer; disc numbers are not read.
