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
mkdir -p "$tmp/formats" "$tmp/art" "$tmp/broken"

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
