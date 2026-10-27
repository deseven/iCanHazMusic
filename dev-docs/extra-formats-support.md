# WavPack and APE support

`.wv` and `.ape` files (and CUE sheets that point to them, the classic whole-album rip) behave like FLAC:
import with tags, lyrics and cover, gapless playback with exact length and sample-exact seeking, waveform, format label
("WV 16/44.1", "APE 24/96"), the same failure handling for missing, stalled and damaged files. The decoders are vendored
(`vendor/`, modules `CWavPack` and `CMonkeysAudio`, see `vendor/README.md`).

This document is the map of how it fits together and what is left. The details live where they belong:
`playback.md` (the sources, what the decoders do), `tag-parsing.md` (the APEv2 path), `cue.md`, `lyrics.md`.

## Facts

- macOS opens neither format: `AudioFile`, `ExtAudioFile`, `AVAudioFile` give `'typ?'`, `AVURLAsset` "Cannot Open". No tags
  either. There is no in-process way to plug a format into Core Audio, hence the decoders.
- Both decoders, read through our own callbacks, decode **bit-exact** and **seek sample-exact** (16/44.1, 24/96, mono, 5.1,
  WavPack float and hybrid with `.wvc`, APE "normal"), on arm64 and x86_64 (both build; the tests ran on arm64).
- Cost (measured before they were wired in; 30 s of 16/44.1 stereo, decoders alone): ~0.12 s WavPack, ~0.14 s APE normal,
  ~0.56 s APE insane: far above real time, but APE "insane" costs several times FLAC. Single threaded (no worker threads).
- Code size: ~50 KB (WavPack) and ~160 KB (APE) of machine code per architecture; ~5 s more for a clean build.
- **Both formats keep their tags in an APEv2 tag at the end of the file** (WavPack may also have an ID3v1). Keys are
  case-insensitive and vary by writer: ffmpeg writes `title`, `artist`, `album`, `date`, `track`; `mac` writes `Title`,
  `Artist`, `Album`, `Year`, `Track`. Cover art is a binary item `Cover Art (Front)`: a file name, a NUL, then the image
  (`wvtag` writes `Cover Art (Front).jpg` as the name, others `cover.jpg`, some nothing). Lyrics: `Lyrics` (sometimes
  `UNSYNCEDLYRICS`).

## How it is built

### Reading audio: `PCMSource` (`src/Core/Playback/Sources/`)

`TrackDecoder` and `WaveformAnalyzer` read a `PCMSource` instead of an `AVAudioFile` (`length`, `processingFormat`,
`framePosition`, `codec`, `seek(to:)`, `read(into:frameCount:)`), made by `PCMSources.open` from the file extension
(`ExtraFormat`: `wv`, `ape`, case-insensitive). Three implementations:

- `AVAudioFileSource`: what the code did before, behind the protocol (the Opus pre-roll is in its `seek`, `SeekPreroll`).
- `WavPackSource`: `WavpackOpenFileInputEx64` with a `WavpackStreamReader64` of ours over `pread`, the `.wvc` next to the file
  as a second stream. Flags: `OPEN_NORMALIZE | OPEN_DSD_AS_PCM`, never `OPEN_TAGS` (the tags are read by `ApeTag`, and the
  library would seek to the end of the file for them).
- `APESource`: `ichm_ape_open` with an `ichm_ape_reader` over `pread`. The shim got one addition, `channel_mask` in
  `ichm_ape_info` (read from the `WAVEFORMATEXTENSIBLE` of the WAV header the SDK stores).
- Shared: `RandomAccessFile` (`open` + `pread`, no cache, an error is the end of the data), `SourceFormat` (the
  `AVAudioFormat` with a channel layout from a WAV speaker mask).

### Edge cases

- **Unknown length** (`WavpackGetNumSamples64` <= 0): the file is refused ("the length of the file is unknown"), not
  decoded to find out. The library already finds the length itself at open when it can seek (it looks at the last block),
  so only a never-finished stream is affected.
- **Hybrid WavPack**: the `.wvc` is looked up next to the file; with it the label is lossless ("WV 16/44.1"), without it
  "WV 240k" (average bit rate of the `.wv`). DSD is decoded to PCM, label "WV DSD64".
- **Channel layout**: speaker mask of the file, else the WAV layout of 3 to 8 channels, else numbered channels (mixed
  alternately left/right). 5.1 in WavPack, APE and FLAC gives the same stereo mix, to the bit.
- **Damage**: a WavPack block that fails its checksum, or an APE frame the SDK can't decode, is a read error: the track ends
  there with a warning, after the audio in front of it. For APE that costs the audio of the whole damaged frame (73728
  samples at the default level).
- **The engine is untouched**: `PlaybackEngine` only sees `TrackDecoder`; only a doc comment changed.
- **Waveform**: each worker opens its own source (both libraries are cheap to open, a decoder is not thread safe). APE can
  only be entered at the start of one of its frames, so a worker that seeks decodes up to the target; WavPack goes to the
  block.

### Files that don't answer

All reads go through our callbacks, on the decoder's own queue, so `TrackDecoder`'s timeout/abandon logic applies as it is
(tested with a named pipe named `x.wv` / `x.ape`: given up after the timeout, released by `cancel()`). Opening reads
headers: WavPack the first block, the Monkey's Audio SDK its descriptor, seek table **and the whole APEv2 tag, a cover
included, at every open** (import, playback, each waveform worker). That is the one cost that scales with the file's tags,
and the SDK has no way to skip it; if it ever shows, the shim could present the file as ending where the tag starts.

### Tags, lyrics, cover (`src/Core/Tags/`)

- `ApeTag`: the APEv2 reader (Swift, no library), walks the items one by one, takes the value of text items only and notes
  where binary ones are (so a cover is never read to find the items behind it). `TrailingTags` (the long MP3 values) uses it
  too. `Id3v1` is the ID3v1 parser, for WavPack files that have one instead of an APEv2 tag, or as well.
- `ApeTagBackend`: for `.wv`/`.ape`, `TagReader.readOne` uses it **instead of the strategy's backends** (AudioFile and
  AVFoundation are never asked about these files), credited as `APEv2`. Duration and the format label come from opening the
  file with its source, which also makes a file the decoder refuses a failed import. Keys go through `TagKeyMap` (case
  insensitive), lyrics come with the other items (no `embeddedLyrics` pass), the cover is detected from its item.
- `RawTags.codec` / `TagReadResult.codec`: the label made at import; `TrackEntry(result:)` uses it instead of the upper-cased
  extension, so the playlist is right from the first import and `PlaybackState` has nothing to correct on the first play
  (the text is the same as the source's, a test pins that). `CueTrack` passes it on to the tracks of a sheet.
- `AlbumArtProcessor.load(.embedded)` (so also `PlaybackArtwork`) reads the image through `ApeTagBackend.embeddedArtwork`.

### Everything that lists formats

- `AudioFileGatherer.supportedExtensions` has `wv` and `ape` (the open panel, drag and drop, playlist import, CUE sheets all
  go through `isSupported`). `.wvc` is not an audio file and is not listed.
- `TagReader.hasAudioHeader`: `wvpk` and `MAC `.
- `CodecLabel.lossless` / `.lossy` are the formatting the sources use; the text is the same wherever it is made.
- Docs: `tag-parsing.md`, `playback.md`, `cue.md`, `lyrics.md`, `vendor/README.md`, `README.md`, `.rules` (the `PCMSource`
  rule, the typecheck command with the module maps, the fixture tools).

## Tests and fixtures

Recipe: `tests/prepare-fixtures.sh` (needs `ffmpeg`, `mac`, `wavpack`, `wvtag`; the output is committed). ffmpeg writes WavPack
(and its tags), `mac` APE, `wavpack` the hybrid pair and the DSD file; what none of them can write is built by hand in the
script: an APE file with a cover (an APEv2 tag appended to the audio, as `mac` writes its own), a WavPack file with only an
ID3v1 tag, the DSF that becomes `dsd.wv`, truncated and damaged copies, garbage.

- `formats/`: `t.wv`, `t.ape` (fully tagged), `t_cover.*`, `l.*` (lyrics), `t_notags.*`, `t_v1.wv`.
- `playback/`: `a.*`, `r96_24.*` (24 bit 96 kHz), `mono22.*`, `surround.*` (5.1 with its mask), `float.wv`, `hybrid.wv` +
  `hybrid.wvc`, `dsd.wv`, `truncated.*`, `damaged.*`; `broken/garbage.wv`, `garbage.ape`.

The existing parameterised tests were extended rather than copied: `TrackDecoderTests` (`exact`, `hiRes`, `startOffset`,
`seekContainers`, `startPastEnd`, `mono`, `surround`, `missing`, `broken`, `truncated`, `timeout`, `cancelReleasesWait`),
`PlaybackEngineTests` (gapless across WV, APE, FLAC and a hybrid file, the label and exact duration, hi-res, mono, 5.1),
`WaveformAnalyzerTests` (levels, workers, truncated), `TagReaderTests` (every strategy, ID3v1, keys, failures, covers),
`LyricsTests`, `CodecLabelTests`, `AudioFileGathererTests`, `ImportSessionTests`, `ArtworkProcessingTests`,
`CueSheetTests`, `CueImportTests` (an APE or WavPack image with a sheet, an embedded cover in one). New:
`PCMSourceTests` (the sources themselves, including seeking, DSD, hybrid with and without the `.wvc`, layouts, damaged files,
`RandomAccessFile`) and `ApeTagTests` (the parser on hand-made tags, covers, ID3v1). `VendoredDecoderTests` is gone: the
sources' tests are the check of the vendored code after an update (`vendor/README.md`).

## Not covered / open

- **Unverified paths**: no fixture for 8 bit, 20 bit or 32 bit integer files, for APE floats, or for APE "insane" and old
  (< 3.98) files. The sample conversion for them is written and uses the same code as the tested depths, but nothing
  runs it. WavPack's legacy (< 4.0) decoder is compiled in and untested too.
- **Tags at the start of the file** (an APEv2 tag without a footer, ID3v2) are not read; the audio plays regardless.
- A WavPack/APE file inside another container (`.mka`), APL link files, Musepack/WMA, writing tags: not in scope.
- Not measured since the integration: the CPU cost of playing or analysing these formats through the engine (the numbers
  above are the decoders alone) and the extra open cost of APE files with a big cover over a network share.
