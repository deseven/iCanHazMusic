# Playback notes

Why playback is built on `AVAudioEngine` + `AVAudioFile` and not on `AVPlayer`/`AVQueuePlayer`, how the engine works,
and what to know before touching it. Everything here was measured (macOS 26, Apple silicon), not assumed.

## Why not AVPlayer

AVFoundation's FLAC support (the demuxer behind `AVPlayer`, `AVAssetReader`, `AVAsset.duration`) has two bugs. They
reproduce with a plain `AVPlayer` and without any app code, so nothing in an app can work around them:

1. **Seeking lands at the wrong place.** The player's clock is set to the requested time, but the audio comes from
   earlier in the file, and the error grows with the position (request 290 s of a 297 s track: audio from 150 s).
   The track then runs past its announced duration and never ends. Checked with `AVAssetReader` against a full decode.
2. **Padding after the last sample.** The duration is counted in whole FLAC packets, so up to a block (4096 frames) of
   exact zeros is played after the last real sample (a file of 6019944 frames plays as 6021120). The audio is cut
   mid-waveform, then silence, then the next track: an audible gap or click, depending on where the track happens
   to end. `AVQueuePlayer` is gapless, but not between items that carry padding.

`AVAudioFile` has neither problem: `length` is the exact number of frames of the file, `framePosition` seeks exactly.
Verified for FLAC (16 bit 44.1 kHz, 24 bit 96 and 192 kHz), WAV, AIFF, CAF, ALAC and MP3 (sample-exact), AAC (exact
from about 1 s, tiny differences before that) and Vorbis (every seek lands a constant 20 ms late).

## How it works

`PlaybackEngine` (`src/Core/Playback/`) plays a queue of two files, the current track and the next one:

- `TrackDecoder`: one per file, with its own serial queue (so a hung read on a network share can be abandoned
  without blocking the next track). Opens the file, folds the channels to stereo (`ChannelDownmix`), resamples to
  the output rate with `AVAudioConverter` and hands out chunks of stereo float32. Resampling with the converter's
  default priming gives exactly `round(frames * outRate / inRate)` frames, no offset and no dependence on chunking.
- Everything is converted to **one format** (stereo float32 at the output's rate), so gapless playback is nothing
  more than contiguous buffers on one `AVAudioPlayerNode`, even between files of different rates and layouts.
- A feeder keeps `lookahead` (5 s) of audio scheduled; the next track's decoder starts when the current one has
  delivered its last frame. Changing the next track after its audio was scheduled rebuilds the queue in place.
- **Position** comes from the node's timeline (`playerTime`), not from completion callbacks. If the feeder ever falls
  behind, the node plays silence and the timeline moves on; the gap is detected when the next buffer is scheduled and
  subtracted from the position.
- Pause, seek, stop and replacing the track **fade the output out** (`node.volume = 0`, ramps in about 25 ms), act
  `fadeDuration` (30 ms) later, and fade back in when playing again. Without it each of them clicks.
- `PlaybackState` keeps the playlist logic (which track follows which, the display) and talks to the engine through
  `start`, `setNext`, `pause`/`resume`, `seek`, `stop` and the events `advanced`, `finished`, `failed`, `deviceError`.

## What the opened file reports

When the decoder opens a file it also learns the exact length (`AVAudioFile.length`) and describes the format
(`CodecLabel`: the file's stream description plus `AudioFile` properties, nothing is decoded). `PlaybackState.tick`
compares both with the playlist's track once per track and, if the length is more than 0.5 s off or missing, or the
label differs, writes them back through `PlaylistStore.updateTrack` (the playlist file is saved again).

- Bit rate: `kAudioFilePropertyBitRate`, the average over the file (MP3, AAC, Vorbis), shown in kbit/s with a `k` (`MP3 CBR 320k`). MP3 is called VBR when the
  largest packet is clearly larger than the average one (`kAudioFilePropertyMaximumPacketSize`), else CBR.
- Lossless (FLAC, ALAC, WAV/AIFF/CAF): bit depth/sample rate instead, as in `FLAC 24/96`. PCM has the depth in its
  stream description; for FLAC and ALAC `AudioFile` gives it as the format flags (1/2/3/4 = 16/20/24/32 bit).

## Things that bit (and are tested)

- **`AVAudioFile.framePosition` raises an Objective-C exception** (which Swift can't catch, so the process dies) for a
  negative position, and `read` throws at/after the end. The decoder clamps the start to `0...length-1` and never
  reads more than `length - framePosition`. A damaged file only makes `read` throw: the track ends there.
- `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil for more than 2 channels without a layout.
- `AVAudioPlayerNode.playerTime` is nil while paused and `lastRenderTime` is invalid before the first render (using it
  raises an exception). The engine keeps its own frame counter for those cases, and guards every use.
- After `stop()` the node's timeline restarts at 0; after `pause()`/`play()` it continues.
- Completion callbacks are unusable here: `.dataPlayedBack` never fires offline, and pending ones fire on `stop()`.
- Mono through the mixer plays 3 dB too quiet, 5.1 clips (peak 2.4), and `AVAudioConverter` silently drops the centre
  and surround channels, so the downmix is done by hand (`ChannelDownmix`: ITU-style, by channel *label*, normalised).
- `mixer.outputVolume` (the user's volume) ramps over about 70 ms, `node.volume` (the fades) over about 25 ms.
- A buffer scheduled on a running node is picked up asynchronously (a few ms). Irrelevant on a device, but an offline
  render right after scheduling can miss it, see `EngineRig.settle`.
- The device may run at any rate (96 kHz on the dev machine): every file is resampled there, nothing is bit-perfect.
  Neither `AVPlayer` nor the engine switches the device rate; that would need CoreAudio HAL access (and exclusive mode).

## CPU usage

Measured on Apple silicon, 44.1 kHz FLAC resampled to a 96 kHz device (engine alone, no UI, ~43 M instructions/s).

- **Where the CPU % comes from depends on how the process is launched.** The same binary, doing the same work (same
  instruction count), shows ~0.9% when started from a terminal and ~2.3% when started through LaunchServices (`open`,
  Finder): the kernel runs most of the latter (~80% of its CPU time) on efficiency cores at ~1.2 GHz instead of on
  performance cores, so the same instructions take longer, while the energy drawn is about a third. Don't compare CPU %
  between runs launched differently, and don't compare against another player without checking how it was launched.
  `taskpolicy -b` reproduces the slow case from a terminal. To check where a process runs, read `proc_pid_rusage`
  (`rusage_info_v6`: `ri_user_ptime`/`ri_system_ptime` vs `ri_user_time`/`ri_system_time`, `ri_cycles`,
  `ri_instructions`, `ri_energy_nj`), no root needed. Instructions per second is the figure to compare.
- **Sample rate converter quality is `.high`, not `.max`.** `.max` costs ~25% more in the converter (13.5 vs 10.1 M
  instructions per second of audio, ~8% of the whole engine). Tone measurements through `AVAudioConverter` (FFT,
  44.1 -> 96 kHz): identical up to the measurement floor (-94 dBc) at 1 and 10 kHz, 18 kHz level -0.013 dB and spurious
  components -129 dBc (`.max`: -139 dBc); the two differ only above ~19 kHz (transition band) and in the rejection of
  ultrasonic aliases (-115 vs -131 dBFS for a 60 kHz tone at 192 -> 96 kHz). `.medium` is measurably worse (-0.7 dB at
  18 kHz, -71 dBFS alias at 192 -> 96 kHz) and saves little more.
- The decoder (FLAC decode + resampling) is the bulk of the engine's cost. The feeder's lookahead (5, 20, 60 s) makes
  no difference to it.

## Not covered by tests

Only the real output device can't be tested: engine start/stop on playback start/end, a changed output device or rate
(`AVAudioEngineConfigurationChange`: the engine restarts and continues from the same position), and the background
feeder/boundary timers. These were smoke-tested once against the real device at volume 0 (gapless advance within
30 ms of the boundary, pause/resume/seek/stop, restart, missing file); device switching needs a manual check.
