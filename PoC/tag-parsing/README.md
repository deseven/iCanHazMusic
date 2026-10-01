# Tag parsing PoC

Fast bulk tag reading for the future SwiftUI rewrite: [`TagReader`](TagReader/TagReader.swift) takes an array
of paths, reads the tags with **standard macOS APIs** (no ffprobe subprocess), reports per-file errors, applies
"Unknown Artist / Track / Album" fallbacks, and streams each result **as soon as it is parsed**, with bounded
parallelism.

Four targets:

| Command | What |
|---|---|
| `./build.sh run` | SwiftUI harness: add/remove folders & files, tracks appear live as they are parsed, live files/s |
| `./build.sh bench` | benchmark + `dump` CLI |
| `./build.sh` | both |

```
swiftc -O -parse-as-library -target arm64-apple-macos15.4 \
    TagReader/*.swift App/App.swift   # or Bench/Bench.swift
```

## TL;DR - the findings

1. **No subprocess needed.** `AudioToolbox` (`AudioFileOpenURL` + `kAudioFilePropertyInfoDictionary`) and
   `AVFoundation` (`AVURLAsset` metadata) both read tags for every container we care about (WAV, AIFF, CAF,
   MP3, AAC/M4A, ALAC, FLAC, OGG Vorbis). WMA/APE/etc. are readable by neither.
2. **AVFoundation is ~2x faster than AudioFile for MP3**, AudioFile is ~1.3x faster for FLAC. Since the
   collection is ~92 % MP3, `TagReader.Strategy.auto` routes `.mp3` to AVFoundation and everything else to
   AudioFile (+ AVFoundation only if the artist is missing). `auto` == pure-AVFoundation speed on MP3 with
   AudioFile's cheaper path for the other formats.
3. **Concurrency pays off a lot on the NAS** (1 → 16 parallel: ~30 → ~160 files/s), but **saturates at ~16**
   for local/NVMe-class storage. Default `concurrency` is now **physical cores / 2**
   (`TagReader.defaultConcurrency`; 4 on an 8-core machine), which is below that NAS sweet spot - pass
   `concurrency: 16` explicitly for a slow network share.
4. **Both APIs read ID3v1** (Apple added it at some point) - the hand-rolled ID3v1 backup read I first wrote
   was dead code and was removed. `ffprobe`-era fallbacks via album_artist/performer/band/composer are kept.
   **ID3v2.2 is the trap:** AVFoundation exposes its 3-char frames (`TT2`, `TP1`, ...) with
   `identifier == nil` and only a bare `key`, so a reader that requires `identifier` silently reports
   "no tags" for those files (found via
   `I Set My Friends On Fire/.../10 Crank That.mp3`). Both that and the missing-artist cases are fixed;
   see *Verification* below.
5. **`AVAsset.duration` is wrong for some OGG files** (535 s vs the real 232.6 s) while AudioFile's
   "approximate duration" matches ffprobe. `TagReader` fills `duration` from whichever backend ran; if
   duration accuracy matters for a format, don't trust the AVFoundation value (or always read duration with
   AudioFile).
6. **ffprobe per file is not faster** (72 files/s at concurrency 16 vs ~155 for AVFoundation) and drags in a
   ~1 MB+ binary, process spawn overhead and no typed errors.

## What each API sees (probe results)

`experiments/api-probe.swift` prints all three candidates for any file; `experiments/make-samples.sh` makes a
tagged sample for each format. Summary, on macOS 26.6 with samples tagged title/artist/album/year/track:

| Container | AudioToolbox `InfoDictionary` | AVFoundation metadata | Notes |
|---|---|---|---|
| MP3 (ID3v2.3/2.4) | title, artist, album, year, track | all items incl. custom | both also read ID3v1 |
| MP3 (ID3v2.2) | title, artist, album, year, track | bare keys, **`identifier` is nil** | see trap above |
| MP3 (ID3v1 only) | title, artist, album, year, track | - | AVFoundation: no metadata formats, AudioFile reads it |
| AAC / ALAC / M4A | complete | complete (`itsk`) | MP4 atom keys start with the Latin-1 byte `0xA9` ("©") |
| FLAC | complete | complete (`vorb/*`) | AVFoundation duration slightly off |
| OGG Vorbis | complete | complete (`vorb/*`) | **AVFoundation duration can be very wrong** |
| WAV | title, artist | title, artist (`caaf/info-*`) | ffmpeg writes no album/year/track here |
| AIFF | title (+ffmpeg's minimal set) | same | same |
| CAF | complete (`track`/`date` keys) | same | |
| WMA / APE / WavPack | **unsupported** | **unsupported** | neither API opens them |

Spotlight (`MDItem`) is useless for these files: it returns the *file name* as title and nil for artists/album.

Supported extensions live in [`AudioFileScanner.supportedExtensions`](TagReader/AudioFileScanner.swift:5)
(`"oga"`/`"opus"` are deliberately excluded for now - see Limitations).

## Benchmark

`bench run` measures whole-library scans on the real NAS
(`/Users/deseven/shares/mus`, SMB, 10567 audio files) with disjoint random sets of album folders per
(round, config) so no run benefits from a warm SMB cache, and shuffles config order per round.

```
build/bench run --list /tmp/mus-files.txt --root /Users/deseven/shares/mus \
    --files 100 --rounds 3 --strategies auto,avFoundation,audioFile,ffprobe --conc 4,16,64
```

Numbers are mean files/s over 3 rounds; "MB/s" is *file size* over wall time (tags only read the head of the
file, so it is not real I/O throughput - it is there to make the sets comparable).

Mixed collection (~92 % MP3):

| Strategy | c=1 | c=4 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|---|
| **auto** | | | 174.7 | 162.6 | 176.6 | |
| avFoundation | 30.3 | 109.5 | 121.6 | 152.6 | 154.4 | 128.7 |
| audioFile | 35.9 | 67.9 | 69.5 | 53.6 | 58.2 | 56.7 |
| ffprobe (old app) | | 56.7 | | 72.2 | | |

FLAC only (764 files in the collection):

| Strategy | c=1 | c=4 | c=16 |
|---|---|---|---|
| audioFile | 59.3 | 116.3 | 136.6 |
| avFoundation | 30.7 | 91.1 | 97.5 |

Reading
- MP3: AVFoundation ~2x AudioFile. FLAC: AudioFile ~1.4x AVFoundation. Hence per-format routing in `auto`.
- Everything scales until ~16 parallel; beyond that the NAS stops helping and per-run variance grows
  (the same config in different rounds can differ by 30 %). Hence the default of 16 rather than 64.
- `audioFile` is *not* faster than `avFoundation` on MP3 despite being a "lower-level" API; AudioFile appears
  to do a fuller pass over the file to build the info dictionary.
- On local/SSD storage the per-file cost is dominated by open/parse (~1-10 ms), and parallel gains saturate
  almost immediately - the NAS numbers are the interesting ones, and they also degrade gracefully on SSD.

## Verification

`bench scan` reads a whole list (no sampling) and can dump every non-complete row to a TSV. Current state of
the 10610-file collection (`auto`, parallel 16, 57 s):

```
ok 10540 | partial 67 (missing artist 53, album 10, title 5) | noTags 3 | FAIL 0
```

- All 70 non-complete rows were cross-checked against `ffprobe`: **0 mismatches**. The files really are
  missing those fields (e.g. *The Kovenant/00- Planetary Black Elements.mp3* has no album tag,
  *Claw The Thin ice/03 Desperate States.mp3* has no title tag) - our "unknown" values are honest, not parse
  failures.
- 150 random files were read and every verdict of `complete` was re-checked with ffprobe: **0 false
  completes**.
- The 3 `noTags` files: two are MPEG-4 **video** files with the extension `.mp3` (`file` says "data",
  ffprobe finds only a video stream), one is an mp3 with an empty ID3 tag - no tags to find, correctly reported.
- The 12 FLACs that failed during one run (`KorovaKill/Waterhells`) were being **renamed by hand while the
  scan was running**; a later run reads them fine. A vanished file is reported as
  `file not found (moved, renamed, or volume unavailable?)` rather than dropped.

## API

```swift
let reader = TagReader(strategy: .auto, concurrency: TagReader.defaultConcurrency, timeout: 30)   // default: physical cores / 2
for await r in reader.read(paths: paths) {          // completion order, one result per input
    switch r.status {
    case .complete:                       // title, artist and album all found
    case .partial(let missing):           // e.g. ["artist"] - fallback applied, listed which
    case .noTags:                         // readable, but no title/artist/album at all
    case .failed(let reason):             // corrupt / unsupported / timed out - reason is human-readable
    }
    r.tags.title, r.tags.artist, r.tags.album   // never empty (Unknown Track/Artist/Album)
    r.tags.year, r.tags.trackNumber, r.tags.duration
    r.sources, r.elapsed, r.rawFields           // via, per-file ms, raw pre-fallback values
}
```

- **Never throws**: failures are per-file data, so one bad file cannot kill a scan.
- **Failure reasons are classified** (AudioToolbox returns an undocumented `'wht?'` and AVFoundation a generic
  "operation could not be completed" for a path that isn't there, so this is verified *only on the failure
  path*, after the read already failed): `file not found (moved, renamed, or volume unavailable?)`,
  `file is empty (0 bytes)`, `unrecognised header (not an audio file?)`, plus the backend's own
  `unsupported file type` / `invalid or corrupt file` / `timed out after N s`.
- **Bounded parallelism**: at most `concurrency` files are in flight; results are yielded as they complete.
- **Blocking work off the cooperative pool**: `AudioFileOpenURL` is synchronous, so it runs on a GCD
  queue with a `timeout` (a stalled NAS mount is reported as `.failed("timed out")` instead of hanging).
- **Artist fallback chain** (same semantics as the old ffprobe code): `artist`, else the last non-empty of
  `album_artist` → `performer` → `band` → `discogs_artist_list` → `composer`.
- Cancelling the consuming task (e.g. removing a folder in the harness) stops new files from starting.
- **Artwork source** (`r.artwork`; detection only, no image is read or decoded). First hit wins:
  1. `.cover(name)`: `cover` / `folder` / `album` / `front` + `jpg` / `jpeg` / `png` in the file's folder, case-insensitive
     (`Cover.JPG`, `FOLDER.png`, ...). If several exist: cover > folder > album > front, then jpg > jpeg > png.
  2. `.embedded`: artwork inside the audio file.
  3. `.anyImage(name)`: any other jpg/jpeg/png in the folder (first in natural order), last resort.
  4. `.none`.

  Hidden files (`._cover.jpg` AppleDouble leftovers on shares) are ignored. Folders are listed **once per
  directory** (cached per `TagReader`, shared by concurrent files), so an album costs one `readdir`.
  Embedded detection only runs when no priority-1 image exists. `TagReader(detectArtwork: false)` turns it
  all off (the benchmarks do, so their numbers stay comparable). Failed files get `.none`.

  How "embedded" is detected (verified with ffmpeg-made samples): via AVFoundation item keys (`APIC`/`PIC`,
  `covr`, common-key artwork, Vorbis `METADATA_BLOCK_PICTURE`). That is free when AVFoundation already read
  the tags, and one extra metadata load otherwise (e.g. non-MP3 files read via AudioFile). **FLAC is the
  exception**: neither AVFoundation nor AudioToolbox exposes its `PICTURE` block (AudioFile claims the
  property exists but returns nothing), so `FlacArtwork` walks the metadata block headers (4 bytes per
  block, image data is skipped). ID3v2.2 `PIC` is handled by key but was not tested (ffmpeg can't write v2.2).

## Files

| File | Purpose |
|---|---|
| [`TagReader/TagModels.swift`](TagReader/TagModels.swift) | `TrackTags`, `TagReadStatus`, `TagReadResult`, fallbacks |
| [`TagReader/TagBackends.swift`](TagReader/TagBackends.swift) | AudioFile / AVFoundation backends + native key → canonical field map |
| [`TagReader/TagReader.swift`](TagReader/TagReader.swift) | the concurrency + normalisation engine described above |
| [`TagReader/AudioFileScanner.swift`](TagReader/AudioFileScanner.swift) | folder → file expansion, supported extensions |
| [`TagReader/ArtworkFinder.swift`](TagReader/ArtworkFinder.swift) | `ArtworkSource`, folder image lookup + per-directory cache |
| [`App/App.swift`](App/App.swift) | SwiftUI harness (sources list, live track table, status bar) |
| [`Bench/Bench.swift`](Bench/Bench.swift) | `dump` (per-file inspection), `run` (disjoint-set benchmark, incl. ffprobe reference), `scan` (whole-list verification, `--problems out.tsv`) |
| [`experiments/`](experiments) | `api-probe.swift` (per-API dump), `make-samples.sh` (tagged samples per format) |

## Harness

`./build.sh run`. Add folders or files (button, ⌘O, or drag & drop), each source is scanned then its files are
read with the chosen strategy/parallelism; rows appear as results arrive, so ordering is completion order.
Columns show the fallback fields in grey italics, per-file status (with the failure reason) and which backend
took how long, and the detected artwork source (image name, or "embedded"). The filter bar above the table toggles status chips (OK / Missing fields / No tags / Failed,
with live counts; multi-select, empty = all) to isolate parsing problems - e.g. show only rows where the
artist or album was missing. Remove sources/rows to cancel work, status bar shows live aggregate counts and files/s. The
strategy/parallelism pickers apply to sources added afterwards (this is a benchmark harness - the point is to
flip the knobs and re-add a folder).

## Limitations / open questions

- **OGG Opus / `.oga`**: tags are readable and AVAudioPlayer *opens* `.opus` but `prepareToPlay()` fails for
  Opus on macOS 26.x (Ogg Vorbis and Ogg-FLAC do play). Per project decision both extensions are excluded from
  the scanner; add them to `supportedExtensions` if that changes. `.opus` inside a `.ogg` file is therefore
  listed but will not play.
- WMA/APE/WavPack/MPC: unsupported by macOS - needs a bundled decoder if ever required.
- `AVFoundationBackend` uses `availableMetadataFormats`; items are read with the modern async `load()` API.
- `discogs_artist_list` only exists as an ID3 `TXXX` frame, which AVFoundation exposes as a private key;
  it is in the fallback chain but will rarely hit.
- Track/disc "N/M" is reduced to the leading integer; disc numbers are not read.
- The harness keeps everything in memory (`LibraryModel.rows`); for a full 10k-file library this is fine
  (the playlist-view PoC handles far more), but a real app should page/sort in the model instead of the view.
