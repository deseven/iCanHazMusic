# Waveform seekbar (implemented, to be tuned and measured)

The second seekbar style is implemented (Preferences > Playback > Seekbar Style: Default / Waveform); what it is and
where it lives is in `.rules` (`Core/Playback/Waveform/`, `SeekbarSettings`, `UI/Playback/WaveformSeekBar.swift`).
This file keeps the background and what is still open. Delete it once the open items are done and the numbers are in
`playback.md`.

## Decisions (as built)

- RMS only, one byte per bucket in dBFS (60 dB range), 2048 buckets per track whatever the length.
- Generated in the background from a separate pass over the file (not from what the engine plays), only for the
  playing track and only while the style is Waveform; two workers (`WaveformAnalyzer.workers`), `.utility` QoS on a
  queue of its own.
- Cached in `.cache/waveforms.sqlite`, keyed by path + size + mtime; never cleared by the app.
- The seekbar is 50 pt high with Waveform; the playback block already derives its maximum width from its measured
  controls height, so the art simply gets smaller.

## Measurements (scratch program, M1, files on an SMB share, 2048 buckets, whole file)

| Track | Workers | Decode only | + peak, RMS |
|---|---|---|---|
| 5 min MP3 320k, 48 kHz | 1 | – | 0.46 s |
| | 2 | 0.24 s | 0.25 s |
| | 4 | 0.14 s | 0.14 s |
| 70 min MP3 320k, 44.1 kHz | 1 | – | 5.9 s |
| | 2 | 3.1 s | 3.1 s |
| | 4 | 1.8 s | 1.8 s |

- Decoding is nearly all of the cost. Splitting the file between workers gave bit-identical results to a sequential
  pass for MP3. In the tests (`WaveformAnalyzerTests`) FLAC, WAV, AIFF, CAF and ALAC are identical too; Vorbis seeks
  20 ms late, so the end of the last slice is cut by that much (the last bucket is measured over what was read).
- At background QoS (efficiency cores) two workers took 0.8 s / 9.4 s. The pass runs at `.utility`, which hasn't been
  measured yet.

## Still to do (needs the app, real tracks)

1. Measure the pass in the app at `.utility` with 2 workers (the 70 min track, from the share) and check the log for
   playback gaps ("the feeder fell behind") while it runs; write the numbers into `playback.md`.
2. Tune by eye, all constants at the top of `WaveformBars` in `WaveformSeekBar.swift`: the overlay opacity (50% as
   asked, maybe 30-40% so the bars stay readable), the position line width (2.5 pt), the height mapping (amplitude
   relative to the loudest column ^ 0.6, cut off 48 dB below it; it was linear in dB over 40 dB, which made
   everything but silence tall), bar width/gap (slot 3 pt, 2/3 bar), the minimum bar height (2 pt), and
   whether the column reduction should be max instead of the power average.
3. Check by hand: switching the style with the block at its maximum size and at the minimum window size (600 pt high:
   the controls grow by 36 pt; the width jumps, maybe animate it), resizing, scrubbing, dark/light, a changed accent
   colour. The position is in whole seconds, so the line may look steppy on short tracks; `livePosition` could drive it.
4. Accessibility: neither bar exposes a value (`position / duration`); do it for both at once.
