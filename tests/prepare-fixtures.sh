#!/bin/sh
# The recipe for the audio/image fixtures used by the tests. The files are committed (tests/fixtures/formats, art,
# broken, playback): run this only to add or change a fixture, not as part of a build.
#
#   ./tests/prepare-fixtures.sh
#
# Requires ffmpeg (with libmp3lame and libopus, as Homebrew's is), Monkey's Audio's `mac` and WavPack's `wavpack` and
# `wvtag` (brew install ffmpeg mac wavpack). Everything else is plain POSIX shell. The four directories are rebuilt from scratch. With the same tool versions the
# output is byte for byte the same (ffmpeg runs `bitexact`), so only the fixtures whose recipe changed show up in git;
# a new ffmpeg may still change every encoded file, so don't regenerate just because a new version is out.
set -e

for tool in ffmpeg mac wavpack wvtag; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool is required to generate the test fixtures (brew install ffmpeg mac wavpack)" >&2
        exit 1
    fi
done

root="$(cd "$(dirname "$0")" && pwd)"
out="$root/fixtures"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/formats" "$tmp/art" "$tmp/broken" "$tmp/playback"

# ffmpeg with the given arguments, the last one being the output file; `bitexact` keeps version strings and other
# varying bits out of the output.
ff() {
    ff_n=$#; ff_i=0
    for ff_arg; do
        ff_i=$(( ff_i + 1 ))
        if [ "$ff_i" -eq "$ff_n" ]; then set -- "$@" -fflags +bitexact -flags +bitexact "$ff_arg"; else set -- "$@" "$ff_arg"; fi
    done
    shift "$ff_n"
    ffmpeg -v error -y "$@"
}

# Monkey's Audio (APE) can't be written by ffmpeg: `mac` compresses a WAV, `-c2000` is its default ("normal") level.
# ape <input wav> <output> [tags as "Name=value|Name=value"]
ape() {
    if [ -n "$3" ]; then mac "$1" "$2" -c2000 -t "$3" >/dev/null 2>&1; else mac "$1" "$2" -c2000 >/dev/null 2>&1; fi
}

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
ff $sine -c:a libopus $T "$f/t.opus"
# WavPack and APE carry APEv2 tags (ffmpeg writes them for .wv; for .ape they are given to `mac`). Neither writes the
# keys the same way: ffmpeg's are lower case (`title`, `date`), `mac`'s capitalised (`Title`, `Year`).
ff $sine $T "$f/t.wv"
ff $sine -map_metadata -1 "$tmp/plain.wav"
ape "$tmp/plain.wav" "$f/t.ape" "Title=TTitle|Artist=TArtist|Album=TAlbum|Year=2020|Track=3"
# the same without any tag
ff $sine -map_metadata -1 "$f/t_notags.wv"
ape "$tmp/plain.wav" "$f/t_notags.ape"

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
v1_tag() {
    printf TAG
    v1 "V1 Title" 30; v1 "V1 Artist" 30; v1 "V1 Album" 30; printf 2011
    head -c 28 /dev/zero; printf '\000\007\377'
}
{ cat "$f/plain.mp3"; v1_tag; } > "$f/t_v1.mp3"
# WavPack files may carry it too, instead of an APEv2 tag
{ cat "$f/t_notags.wv"; v1_tag; } > "$f/t_v1.wv"

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
ff $sine -c:a libopus $T -metadata "lyrics=$LYRICS" "$f/l.opus"
ff $sine -c:a aac $T -metadata "lyrics=$LYRICS" "$f/l_aac.m4a"
ff $sine -c:a alac $T -metadata "lyrics=$LYRICS" "$f/l_alac.m4a"
ff $sine $T -metadata "lyrics=$LYRICS" "$f/l.caf"
ff $sine $T -metadata "lyrics=$LYRICS" "$f/l.wv"
ape "$tmp/plain.wav" "$f/l.ape" "Title=TTitle|Artist=TArtist|Album=TAlbum|Year=2020|Track=3|Lyrics=$LYRICS"
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
# ffmpeg can't put a picture into Ogg Opus: the cover goes in as a METADATA_BLOCK_PICTURE comment, which is what
# opusenc writes: a FLAC picture block (type 3 = front cover, mime, empty description, width, height, depth, colours,
# length, data; integers big-endian u32) in base64.
be32() { printf "\\$(printf %03o $(( ($1 >> 24) & 255 )))"; be24 $(( $1 & 16777215 )); }
picture=$({
    be32 3; be32 10; printf image/jpeg; be32 0; be32 300; be32 200; be32 24; be32 0
    be32 "$(wc -c < "$a/cover.jpg" | tr -d ' ')"; cat "$a/cover.jpg"
} | base64)
ff $sine -c:a libopus $T -metadata "METADATA_BLOCK_PICTURE=$picture" "$f/t_cover.opus"

# WavPack and APE keep a cover in a binary APEv2 item `Cover Art (Front)`: a file name, a NUL, the image. `wvtag` writes
# it for WavPack (with a tag header, and the file name "Cover Art (Front).jpg"). `mac` can't, so for APE the tag is made
# by hand and appended to the audio, the way `mac` writes its own tags: items (value size, flags: 0 text / 2 binary, key,
# NUL, value), then a footer without a header (`APETAGEX`, version 2000, size of items + footer, item count, flags, 8
# reserved bytes).
le32() { printf "\\$(printf %03o $(( $1 & 255 )))\\$(printf %03o $(( ($1 >> 8) & 255 )))\\$(printf %03o $(( ($1 >> 16) & 255 )))\\$(printf %03o $(( ($1 >> 24) & 255 )))"; }
ape_text() { le32 $(printf '%s' "$2" | wc -c | tr -d ' '); le32 0; printf '%s\000%s' "$1" "$2"; }
ape_cover() { le32 $(( ${#1} + 1 + $(wc -c < "$2" | tr -d ' ') )); le32 2; printf 'Cover Art (Front)\000%s\000' "$1"; cat "$2"; }
cp "$f/t.wv" "$f/t_cover.wv"
wvtag -q --write-binary-tag "Cover Art (Front)=@$a/cover.jpg" "$f/t_cover.wv"
{
    ape_text Title TTitle; ape_text Artist TArtist; ape_text Album TAlbum; ape_text Year 2020; ape_text Track 3
    ape_cover cover.jpg "$a/cover.jpg"
} > "$tmp/ape.items"
ape "$tmp/plain.wav" "$f/t_cover.ape"
{
    cat "$tmp/ape.items"
    printf APETAGEX; le32 2000; le32 $(( $(wc -c < "$tmp/ape.items" | tr -d ' ') + 32 )); le32 6; le32 $(( 1 << 30 )); head -c 8 /dev/zero
} >> "$f/t_cover.ape"

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
ramp "$p/a.wv"          44100 2 136710 0     s16p 16 -c:a wavpack
ape "$p/a.wav" "$p/a.ape"
# The same kinds of file as the FLAC ones above, in WavPack and APE (`mac` compresses a WAV made on the side). A higher
# compression level keeps the 24 bit WavPack a quarter of the size.
ramp "$p/r96_24.wv"     96000 2 192000 400   s32p 24 -c:a wavpack -bits_per_raw_sample 24 -compression_level 3
ramp "$tmp/r96_24.wav"  96000 2 192000 400   s32 24 -c:a pcm_s24le
ape "$tmp/r96_24.wav" "$p/r96_24.ape"
ramp "$p/mono22.wv"     22050 1 33075  500   s16p 16 -c:a wavpack
ramp "$tmp/mono22.wav"  22050 1 33075  500   s16 16 -c:a pcm_s16le
ape "$tmp/mono22.wav" "$p/mono22.ape"
# 5.1 with the channel mask of a WAV file (front, centre, LFE, back)
ramp "$p/surround.wv"   44100 6 66150  600   s16p 16 -c:a wavpack
ramp "$tmp/surround.wav" 44100 6 66150 600   s16 16 -c:a pcm_s16le
ape "$tmp/surround.wav" "$p/surround.ape"
# 32 bit float samples: the values are the 16 bit ones, which a float holds exactly
ramp "$p/float.wv"      44100 2 136710 700   fltp 16 -c:a wavpack
# Hybrid WavPack: a lossy .wv and the correction file that makes it lossless again
wavpack -q -b128 -c -f "$p/a.wav" -o "$p/hybrid.wv"
# DSD64, stereo, 8 blocks of 4096 bytes per channel (a Sony DSF file made by hand: header, format, data), as WavPack
# stores it. The pattern 0x69 is DSD's silence.
le64() { le32 "$1"; le32 0; }
{
    printf 'DSD '; le64 28; le64 $(( 28 + 52 + 12 + 8 * 4096 * 2 )); le64 0
    printf 'fmt '; le64 52; le32 1; le32 0; le32 2; le32 2; le32 2822400; le32 1; le64 $(( 8 * 4096 * 8 )); le32 4096; le32 0
    printf 'data'; le64 $(( 12 + 8 * 4096 * 2 ))
    head -c $(( 8 * 4096 * 2 )) /dev/zero | tr '\000' '\151'
} > "$tmp/dsd.dsf"
wavpack -q "$tmp/dsd.dsf" -o "$p/dsd.wv" 2>/dev/null
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
ff -f lavfi -i "anoisesrc=d=3:c=pink:a=0.3:seed=1" -ac 2 -c:a libmp3lame -q:a 2 "$p/lossy_vbr.mp3"
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a aac "$p/lossy.m4a"
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a vorbis -strict -2 "$p/lossy.ogg"
# Opus is always 48 kHz; its decoder needs some audio before a seek target to be right there (see TrackDecoder)
ff -f lavfi -i "sine=d=3:f=440" -ac 2 -c:a libopus "$p/lossy.opus"
# a FLAC cut in the middle: the header still promises the full length
head -c 60000 "$p/a.flac" > "$p/truncated.flac"
head -c 60000 "$p/a.wv" > "$p/truncated.wv"
head -c 60000 "$p/a.ape" > "$p/truncated.ape"
# the same length, but 64 bytes in the middle are overwritten
damage() { cp "$1" "$2"; head -c 64 /dev/zero | tr '\000' '\125' | dd of="$2" bs=1 seek="$3" conv=notrunc 2>/dev/null; }
damage "$p/a.wv" "$p/damaged.wv" 80000
damage "$p/a.ape" "$p/damaged.ape" 60000

# ---------------------------------------------------------------- broken files
b="$tmp/broken"
head -c 5000 "$f/t_v23.mp3" > "$b/truncated.mp3"
echo garbage > "$b/garbage.mp3"
echo garbage > "$b/garbage.wv"
echo garbage > "$b/garbage.ape"
: > "$b/empty.flac"
# an MPEG-4 video that pretends to be an mp3
ff -f lavfi -i testsrc=s=64x64:d=1 -c:v mpeg4 -f mp4 "$b/video.mp3"

for dir in formats art broken playback; do
    rm -rf "${out:?}/$dir"
    mv "$tmp/$dir" "$out/$dir"
done
echo "fixtures written to $out"
