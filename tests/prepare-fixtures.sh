#!/bin/sh
# Generates the audio/image fixtures used by the tests into tests/fixtures/generated (git-ignored).
#
#   ./tests/prepare-fixtures.sh
#
# Requires ffmpeg (brew install ffmpeg). Everything else is plain POSIX shell.
# Safe to re-run: the output directory is rebuilt from scratch.
set -e

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "error: ffmpeg is required to generate the test fixtures (brew install ffmpeg)" >&2
    exit 1
fi

root="$(cd "$(dirname "$0")" && pwd)"
out="$root/fixtures/generated"
tmp="$root/fixtures/.generated.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/formats" "$tmp/art" "$tmp/broken" "$tmp/playback"

ff() { ffmpeg -v error -y "$@"; }

# Every audio fixture is a 2 second sine wave. Tagged ones carry exactly these values
# (the tests rely on them, see Fixtures.swift):
T="-metadata title=TTitle -metadata artist=TArtist -metadata album=TAlbum -metadata date=2020 -metadata track=3"
sine="-f lavfi -i sine=d=2"

# ---------------------------------------------------------------- formats, fully tagged
f="$tmp/formats"
ff $sine $T "$f/t.wav"
ff $sine $T "$f/t.aiff"
ff $sine $T "$f/t.caf"
ff $sine -c:a alac $T "$f/t_alac.m4a"
ff $sine -c:a aac $T "$f/t_aac.m4a"
ff $sine $T "$f/t.flac"
# ffmpeg's native Vorbis encoder is stereo only and still flagged experimental
ff $sine -ac 2 -c:a vorbis -strict -2 $T "$f/t.ogg"
ff $sine -c:a libmp3lame -id3v2_version 3 $T "$f/t_v23.mp3"
ff $sine -c:a libmp3lame -id3v2_version 4 $T "$f/t_v24.mp3"

# ---------------------------------------------------------------- mp3 without any tag (also used as a base)
ff $sine -c:a libmp3lame -write_xing 0 -id3v2_version 0 -map_metadata -1 "$f/plain.mp3"

# ID3v2.2 (3 character frame ids) is something ffmpeg can't write: AVFoundation exposes those frames with a
# nil identifier, so it is worth having a real file. Frame: id(3) + size(3, big endian) + encoding(0) + text.
be24() { printf "\\$(printf %03o $(( ($1 >> 16) & 255 )))\\$(printf %03o $(( ($1 >> 8) & 255 )))\\$(printf %03o $(( $1 & 255 )))"; }
v22_frame() { printf '%s' "$1"; be24 $(( ${#2} + 1 )); printf '\000%s' "$2"; }
{
    v22_frame TT2 TTitle
    v22_frame TP1 TArtist
    v22_frame TAL TAlbum
    v22_frame TYE 2020
    v22_frame TRK 3
} > "$tmp/v22.frames"
size=$(wc -c < "$tmp/v22.frames" | tr -d ' ')
{
    printf 'ID3\002\000\000'
    printf "\\000\\000\\$(printf %03o $(( (size >> 7) & 127 )))\\$(printf %03o $(( size & 127 )))"
    cat "$tmp/v22.frames"
    cat "$f/plain.mp3"
} > "$f/t_v22.mp3"
rm "$tmp/v22.frames"

# ID3v1 only: 'TAG' + title(30) + artist(30) + album(30) + year(4) + comment(28) + 0 + track + genre
v1() { printf '%s' "$1" | dd bs="$2" count=1 conv=sync 2>/dev/null; }
{
    cat "$f/plain.mp3"
    printf TAG
    v1 "V1 Title" 30; v1 "V1 Artist" 30; v1 "V1 Album" 30; printf 2011
    head -c 28 /dev/zero; printf '\000\007\377'
} > "$f/t_v1.mp3"

# ---------------------------------------------------------------- artist fallback chain
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata title=TTitle -metadata album=TAlbum -metadata album_artist=TAlbumArtist "$f/t_albumartist.mp3"
ff $sine -metadata title=TTitle -metadata album=TAlbum -metadata album_artist=TAlbumArtist -metadata composer=TComposer "$f/t_albumartist.flac"
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata title=TTitle -metadata album=TAlbum -metadata composer=TComposer "$f/t_composer.mp3"

# ---------------------------------------------------------------- partial / no / odd tags
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata artist=OnlyArtist "$f/t_onlyartist.mp3"
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata title="Тест ☃ 日本語" -metadata artist="Björk" -metadata album="Ünïcode Album" "$f/t_unicode.mp3"
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata title=TTitle -metadata artist=TArtist -metadata album=TAlbum -metadata track=7/12 -metadata date=2019-05-06 "$f/t_track_of_total.mp3"
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata title=OnlyTitle "$f/t_onlytitle.mp3"
ff $sine -c:a libmp3lame -id3v2_version 3 -metadata comment=whatever "$f/t_notags.mp3"
ff $sine -metadata comment=whatever "$f/t_notags.flac"

# ---------------------------------------------------------------- lyrics
# Every lyrics fixture carries these values (see Fixtures.lyrics) next to the usual tags: four lines, one of them
# empty, one non-ASCII.
LYRICS="Line one
Line two

Line four ünï ☃"
ff $sine $T -metadata "lyrics=$LYRICS" "$f/l.flac"
ff $sine -ac 2 -c:a vorbis -strict -2 $T -metadata "lyrics=$LYRICS" "$f/l.ogg"
ff $sine -c:a aac $T -metadata "lyrics=$LYRICS" "$f/l_aac.m4a"
ff $sine -c:a alac $T -metadata "lyrics=$LYRICS" "$f/l_alac.m4a"
ff $sine $T -metadata "lyrics=$LYRICS" "$f/l.caf"
# FLAC's other comment name for it
ff $sine $T -metadata "UNSYNCEDLYRICS=$LYRICS" "$f/l_unsynced.flac"
# lyrics, but no artist: nothing to file them under
ff $sine -metadata title=TTitle -metadata album=TAlbum -metadata "lyrics=$LYRICS" "$f/l_noartist.flac"

# ffmpeg writes no USLT frame for MP3, so it is made by hand: an ID3v2.4 tag (frame sizes are sync-safe) with
# UTF-8 text frames and a USLT frame (encoding 3, language, empty descriptor, text), then the audio of plain.mp3.
ss32() { printf "\\$(printf %03o $(( ($1 >> 21) & 127 )))\\$(printf %03o $(( ($1 >> 14) & 127 )))\\$(printf %03o $(( ($1 >> 7) & 127 )))\\$(printf %03o $(( $1 & 127 )))"; }
v24_text() { printf '%s' "$1"; ss32 $(( ${#2} + 1 )); printf '\000\000\003%s' "$2"; }
v24_uslt() {
    printf 'USLT'; ss32 $(( $(printf '%s' "$1" | wc -c | tr -d ' ') + 5 )); printf '\000\000\003eng\000%s' "$1"
}
{
    v24_text TIT2 TTitle
    v24_text TPE1 TArtist
    v24_text TALB TAlbum
    v24_uslt "$LYRICS"
} > "$tmp/v24.frames"
size=$(wc -c < "$tmp/v24.frames" | tr -d ' ')
{
    printf 'ID3\004\000\000'; ss32 "$size"
    cat "$tmp/v24.frames"
    cat "$f/plain.mp3"
} > "$f/l_v24.mp3"
rm "$tmp/v24.frames"

# ---------------------------------------------------------------- images
a="$tmp/art"
ff -f lavfi -i testsrc=s=300x200 -frames:v 1 "$a/cover.jpg"          # landscape
ff -f lavfi -i testsrc=s=200x300 -frames:v 1 "$a/portrait.png"       # portrait, opaque
ff -f lavfi -i testsrc=s=200x200 -frames:v 1 "$a/square.jpg"
ff -f lavfi -i color=c=red@0.5:s=200x300 -frames:v 1 -pix_fmt rgba "$a/alpha.png"
echo "not an image" > "$a/broken.jpg"

# ---------------------------------------------------------------- embedded artwork
ff $sine -i "$a/cover.jpg" -map 0 -map 1 -c:a libmp3lame -c:v copy -id3v2_version 3 -disposition:v attached_pic $T "$f/t_cover.mp3"
ff $sine -i "$a/cover.jpg" -map 0 -map 1 -c:a aac -c:v copy -disposition:v attached_pic $T "$f/t_cover.m4a"
ff $sine -i "$a/cover.jpg" -map 0 -map 1 -c:a flac -c:v copy -disposition:v attached_pic $T "$f/t_cover.flac"

# ---------------------------------------------------------------- playback: sample-exact ramps
# Playback tests compare what the engine renders with the file content, sample by sample. A sine wave would hide
# an off-by-some-samples error, so these files hold a sawtooth that is different in every channel and every
# file (`salt`): the value of frame n of channel c is ((n * step_c + salt) mod 2^bits) - 2^(bits-1), as an
# integer. Lengths are deliberately not multiples of the FLAC block size (4096).
p="$tmp/playback"
mkdir -p "$p"

# ramp <file> <rate> <channels> <frames> <salt> <ffmpeg sample_fmt> <bits> [extra output options...]
ramp() {
    ramp_file="$1"; ramp_rate="$2"; ramp_ch="$3"; ramp_frames="$4"; ramp_salt="$5"; ramp_fmt="$6"; ramp_bits="$7"
    shift 7
    ramp_range=$(( 1 << ramp_bits )); ramp_half=$(( ramp_range / 2 ))
    ramp_exprs=""
    ramp_c=0
    while [ "$ramp_c" -lt "$ramp_ch" ]; do
        ramp_step=$(( 7 + 6 * ramp_c ))
        ramp_e="mod(n*$ramp_step+$ramp_salt\\,$ramp_range)/$ramp_half-1"
        if [ -z "$ramp_exprs" ]; then ramp_exprs="$ramp_e"; else ramp_exprs="$ramp_exprs|$ramp_e"; fi
        ramp_c=$(( ramp_c + 1 ))
    done
    case "$ramp_ch" in 1) ramp_layout=mono ;; 2) ramp_layout=stereo ;; 6) ramp_layout=5.1 ;; esac
    # The length is given as a duration with enough digits to hit `frames` exactly (checked by the tests).
    ramp_dur=$(awk -v f="$ramp_frames" -v r="$ramp_rate" 'BEGIN { printf "%.9f", f / r }')
    ff -f lavfi -i "aevalsrc=exprs=$ramp_exprs:s=$ramp_rate:c=$ramp_layout:d=$ramp_dur" -sample_fmt "$ramp_fmt" "$@" "$ramp_file"
}

ramp "$p/a.flac"        44100 2 136710 0     s16 16 -c:a flac
ramp "$p/b.flac"        44100 2 110250 5000  s16 16 -c:a flac
ramp "$p/c.flac"        44100 2 88200  9000  s16 16 -c:a flac
ramp "$p/tiny.flac"     44100 2 2205   100   s16 16 -c:a flac
ramp "$p/tiny2.flac"    44100 2 1500   200   s16 16 -c:a flac
ramp "$p/r48.flac"      48000 2 96000  300   s16 16 -c:a flac
ramp "$p/r96_24.flac"   96000 2 192000 400   s32 24 -c:a flac -bits_per_raw_sample 24
ramp "$p/mono22.flac"   22050 1 33075  500   s16 16 -c:a flac
ramp "$p/surround.flac" 44100 6 66150  600   s16 16 -c:a flac
ramp "$p/a.wav"         44100 2 136710 0     s16 16 -c:a pcm_s16le
ramp "$p/a.aiff"        44100 2 136710 0     s16 16 -c:a pcm_s16be
ramp "$p/a.caf"         44100 2 136710 0     s16 16 -c:a pcm_s16le
ramp "$p/a_alac.m4a"    44100 2 136710 0     s16p 16 -c:a alac
# tone <file> <rate> <channels> <frames> <frequency> <ffmpeg sample_fmt> [extra output options...]
# A sine wave, 0.5 amplitude in the first channel and 0.25 in the second (so swapped channels are noticed).
# Used where the exact samples can't be predicted (resampling) but the waveform can: the tests compare the
# rendered audio with the analytic sine, and a click shows up as a step between two neighbouring samples.
tone() {
    tone_file="$1"; tone_rate="$2"; tone_ch="$3"; tone_frames="$4"; tone_freq="$5"; tone_fmt="$6"
    shift 6
    tone_exprs="0.5*sin(2*PI*$tone_freq*t)"
    if [ "$tone_ch" -ge 2 ]; then tone_exprs="$tone_exprs|0.25*sin(2*PI*$tone_freq*t)"; fi
    case "$tone_ch" in 1) tone_layout=mono ;; 2) tone_layout=stereo ;; esac
    tone_dur=$(awk -v f="$tone_frames" -v r="$tone_rate" 'BEGIN { printf "%.9f", f / r }')
    ff -f lavfi -i "aevalsrc=exprs=$tone_exprs:s=$tone_rate:c=$tone_layout:d=$tone_dur" -sample_fmt "$tone_fmt" "$@" "$tone_file"
}

tone "$p/sine44.flac"      44100 2 132300 1000 s16 -c:a flac
tone "$p/sine48.flac"      48000 2 96000  1000 s16 -c:a flac
tone "$p/sine32.flac"      32000 2 64000  1000 s16 -c:a flac
tone "$p/sine96_24.flac"   96000 2 192000 1000 s32 -c:a flac -bits_per_raw_sample 24
tone "$p/sine22_mono.flac" 22050 1 44100  1000 s16 -c:a flac
# lossy formats: length and seeking can only be approximately checked
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a libmp3lame "$p/lossy.mp3"
# VBR (noise, so the frames differ in size)
ff -f lavfi -i "anoisesrc=d=3:c=pink:a=0.3" -ac 2 -c:a libmp3lame -q:a 2 "$p/lossy_vbr.mp3"
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a aac "$p/lossy.m4a"
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a vorbis -strict -2 "$p/lossy.ogg"
# a FLAC cut in the middle: the header still promises the full length
head -c 60000 "$p/a.flac" > "$p/truncated.flac"

# ---------------------------------------------------------------- broken files
b="$tmp/broken"
head -c 5000 "$f/t_v23.mp3" > "$b/truncated.mp3"
echo garbage > "$b/garbage.mp3"
: > "$b/empty.flac"
# an MPEG-4 video that pretends to be an mp3
ff -f lavfi -i testsrc=s=64x64:d=1 -c:v mpeg4 -f mp4 "$b/video.mp3"

rm -rf "$out"
mv "$tmp" "$out"
echo "fixtures written to $out"
