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
from about 1 s, tiny differences before that), Vorbis (every seek lands a constant 20 ms late) and Opus (sample-exact,
but only with a pre-roll, see below).

**Opus needs a pre-roll.** `AVAudioFile` lands on the right frame but starts the Opus decoder there with no history: the
first ~150 ms after a seek come out faded in and distorted. So every seek (decoder start, waveform slice) goes through
`AVAudioFile.seekPrerolled`, which starts 0.5 s earlier and drops that audio (`SeekPreroll`: 80 ms, what libopus suggests,
leaves an error of -21 dB, 250 ms -71 dB, 400 ms none). Without it every seek, restore and CUE track that starts
mid-file would begin with a fade-in. Its length (exact) and the decode from the start match `opusdec` sample for sample.
Multichannel Opus doesn't open at all (`'fmt?'`).

## How it works

`PlaybackEngine` (`src/Core/Playback/`) plays a queue of two files, the current track and the next one:

- `TrackDecoder`: one per file, with its own serial queue (so a hung read on a network share can be abandoned
  without blocking the next track). Opens the file, folds the channels to stereo (`ChannelDownmix`), resamples to
  the output rate with `AVAudioConverter` and hands out chunks of stereo float32. Resampling with the converter's
  default priming gives exactly `round(frames * outRate / inRate)` frames, no offset and no dependence on chunking.
- Everything is converted to **one format** (stereo float32 at the output's rate), so gapless playback is nothing
  more than contiguous buffers on one `AVAudioPlayerNode`, even between files of different rates and layouts.
- A feeder keeps `lookahead` (5 s by default, Preferences > Engine > Read-Ahead Buffer) of audio scheduled; the next track's decoder starts when the current one has
  delivered its last frame. Changing the next track after its audio was scheduled rebuilds the queue in place.
- **Position** comes from the node's timeline (`playerTime`), not from completion callbacks. If the feeder ever falls
  behind, the node plays silence and the timeline moves on; the gap is detected when the next buffer is scheduled and
  subtracted from the position.
- Pause, seek, stop and replacing the track **fade the output out** (`node.volume = 0`, ramps in about 25 ms), act
  `fadeDuration` (30 ms) later, and fade back in when playing again. Without it each of them clicks.
- `PlaybackState` keeps the playlist logic (which track follows which, the display) and talks to the engine through
  `start`, `setNext`, `pause`/`resume`, `seek`, `stop` and the events `started`, `advanced`, `finished`, `failed`,
  `deviceError`. `started` comes when the current track's first audio is scheduled (after any start, seek or restart):
  only then does the track count as playing for the listeners (Last.fm, LRCLIB, notifications) and the log.

## Files that don't answer

A file on a network share that went away (SMB mounts are hard mounts by default) can block `AVAudioFile`'s open or read
in the kernel for a long time, and nothing can interrupt that call. This used to wedge playback: the feeder is a single
loop that awaited the decoder, so after one hung read no track was ever fed again until Stop (the UI showed "playing"
with a seek bar jumping back to 0). Now:

- `TrackDecoder.next()` returns `.finished` at once when its decoder is cancelled (every dropped slot is), so the
  feeder moves on; the blocked call finishes in the background whenever the system lets it, its result is dropped.
- Every `next()` call has a timeout (`PlaybackEngine.decoderTimeout`, 10 s): a file that delivered nothing fails
  ("no answer from the file"), one that did ends its track there. A sleeping NAS disk that takes longer to spin up
  than that counts as not answering.
- `PlaybackState` skips a failed track, and gives up after 10 failures in a row (sheet on the main window).
- The position never runs past what was scheduled, and `isAudible` is false while nothing comes out, so the seek bar
  stands still instead of running ahead.

## Long pauses

Pausing only pauses the player node; the device engine keeps running, which keeps the device busy and holds a
`PreventUserIdleSystemSleep` assertion (coreaudiod, attributed to the app: `pmset -g assertions`). After
`pauseReleaseDelay` (60 s) the engine lets go of the output (`releaseIdleOutput`): player, decoders and device engine
are stopped, the position and the next track are kept, and `resume` restarts from there with a freshly started output.

## Restoring playback at launch

`playback.state` in `config.json` (`{playlist, track_id, position, paused}`) is what the last run left; it lives in the
config and not in the playlist files (which are rewritten whole on every save, and are about content, not about what
happens to be playing). Written by `PlaybackState.saveState`, so it is always true to within ~10 s, and exact after a
pause, a seek or a quit; every stop clears it, except the one at quit (`stopAndWait` keeps it).

- `restorePlayback()` (called from `AppDelegate`) reads the playlist the track is in on demand
  (`PlaylistStore.readPlaylist`, so it needn't wait for the preload of all the others), finds the track by ID and calls
  `begin(_:resume:)`, which hands the engine `start(source, at: position, playing: !paused)`.
- A paused restore loads the file (the duration shows, the track is announced to the listeners) and arms the usual
  `pauseReleaseDelay`, so the output is not held for a track nobody resumes.
- Position and length of a CUE track are relative to the part, as everywhere; the engine adds the part's start.
- A track that can't be opened stops playback instead of moving to the next one: the usual skip-on is for an album
  that has a bad file, here the likely cause is a network share that isn't mounted yet, and everything after it is on
  the same share.

### Scrobbling across a restart

The config doesn't (and shouldn't) hold how much of the track was listened to. So:

- Quitting is not the end of the track: no `trackDidEnd` (`endProgress(report: false)`), otherwise Last.fm would get
  the scrobble at quit and a second one after the restore.
- A restored track is a `PlayProgress(resumedAt:)`. Picked up at >= 50% of its length (`LastFMService.scrobbleThreshold`)
  it counts as listened to up to that position (`listened(ofDuration:)` = what was heard since + the position); earlier
  it counts from 0. Either way the listening done after the restore adds to it, and it's capped at the track length.
- The track's `startedAt` (the time Last.fm gets with the scrobble) is back-dated by the position.
- The restored track is announced to the listeners when its audio starts (also when it is paused), like any other:
  Last.fm's "now playing" is sent, lyrics and the waveform are loaded.

## Diagnosing hangs

- `SlowCallLog`: every CoreAudio call the engine makes on the main thread (`AVAudioEngine.start/stop/prepare`, the
  node's `play/pause/stop/playerTime`, binding the device) is timed; those over 0.5 s are logged (rate limited).
- `MainThreadWatchdog` logs any UI hang of 2 s or more, and once at 10 s if it is still stuck.
- Sleep/wake and the output device name (on every output start) are in the log too. The log of the last 4 runs is
  kept (`app.log.1` ...). For a hang in progress, `sample <pid> 10` shows where the main thread is stuck.

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
- The output device is the system default unless one is chosen (`outputDeviceUID`). Pinning one (`AUAudioUnit.setDeviceID` on the output node, before the engine starts) makes the engine stop following the system default, so going back to the default needs a new `AVAudioEngine`. The device is looked up only when the output starts; one that is gone is dropped for the default.
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
- **Sample rate converter quality defaults to `.high`, not `.max`** (selectable in Preferences, `engine.resample_quality`). `.max` costs ~25% more in the converter (13.5 vs 10.1 M
  instructions per second of audio, ~8% of the whole engine). Tone measurements through `AVAudioConverter` (FFT,
  44.1 -> 96 kHz): identical up to the measurement floor (-94 dBc) at 1 and 10 kHz, 18 kHz level -0.013 dB and spurious
  components -129 dBc (`.max`: -139 dBc); the two differ only above ~19 kHz (transition band) and in the rejection of
  ultrasonic aliases (-115 vs -131 dBFS for a 60 kHz tone at 192 -> 96 kHz). `.medium` is measurably worse (-0.7 dB at
  18 kHz, -71 dBFS alias at 192 -> 96 kHz) and saves little more.
- The decoder (FLAC decode + resampling) is the bulk of the engine's cost. The feeder's lookahead (5, 20, 60 s) makes
  no difference to it.

## Not covered by tests

Only the real output device can't be tested: engine start/stop on playback start/end, a changed output device or rate
(`AVAudioEngineConfigurationChange`: the engine restarts and continues from the same position), the background
feeder/boundary timers, the timer that releases the output after a pause (offline tests call `releaseIdleOutput`
themselves) and keeping the output running across a failed track. These were smoke-tested once against the real device at volume 0 (gapless advance within
30 ms of the boundary, pause/resume/seek/stop, restart, missing file); device switching needs a manual check.
