#!/bin/sh
# Generates a tagged sample file (plus edge cases) for every container we support, into $1 (default /tmp/tagsamples).
# Requires ffmpeg. Use `bench dump` on the result to check what gets parsed:
#   ./make-samples.sh /tmp/tagsamples && ../build/bench dump /tmp/tagsamples
set -e
dir="${1:-/tmp/tagsamples}"
mkdir -p "$dir"
T="-metadata title=TTitle -metadata artist=TArtist -metadata album=TAlbum -metadata date=2020 -metadata track=3"
sine="-f lavfi -i sine=d=2"

ffmpeg -v error -y $sine $T "$dir/t.wav"
ffmpeg -v error -y $sine $T "$dir/t.aiff"
ffmpeg -v error -y $sine $T "$dir/t.caf"
ffmpeg -v error -y $sine -c:a alac $T "$dir/t_alac.m4a"
ffmpeg -v error -y $sine -c:a aac $T "$dir/t_aac.m4a"
ffmpeg -v error -y $sine -c:a libopus $T "$dir/t.opus"
ffmpeg -v error -y $sine $T "$dir/t.flac"
ffmpeg -v error -y $sine -c:a libmp3lame -id3v2_version 3 $T "$dir/t.mp3"
# mp3 with only an ID3v1 tag (no ID3v2): written by hand, ffmpeg alone will not do it
ffmpeg -v error -y $sine -c:a libmp3lame -write_xing 0 -id3v2_version 0 -map_metadata -1 "$dir/t_v1.mp3"
python3 - "$dir/t_v1.mp3" <<'EOF'
import sys
f = lambda s, n: s.encode()[:n].ljust(n, b'\0')
tag = b'TAG' + f('V1 Title',30) + f('V1 Artist',30) + f('V1 Album',30) + b'2011' + f('',28) + b'\0' + bytes([7]) + bytes([255])
assert len(tag) == 128
open(sys.argv[1], 'ab').write(tag)
EOF
# edge cases
ffmpeg -v error -y $sine -c:a libmp3lame -id3v2_version 3 "$dir/t_notags.mp3"
ffmpeg -v error -y $sine "$dir/t_notags.flac"
head -c 5000 "$dir/t.mp3" > "$dir/broken_trunc.mp3"
echo garbage > "$dir/garbage.mp3"
: > "$dir/empty.flac"
echo "samples in $dir"
ls -l "$dir"
