#!/bin/sh
# Copies the decoders the app compiles in from their upstream releases into vendor/ (see vendor/README.md).
#
#   ./vendor/update.sh
#
# To update: change a version below, run this, build (`swift build -c debug --arch arm64`), run the tests, and update
# the versions in vendor/README.md. Never edit the copied files: our own code lives next to them (`shim/`), which this
# script doesn't touch. Needs git, curl and unzip; downloads into a temporary directory.
set -e

wavpack_tag="5.9.0"
monkeys_version="1343"   # 13.43, the SDK zip is named after it
# The SDK zip is not signed and has no git history: its hash is checked so that an update is a deliberate change here.
monkeys_sha256="3fd1c60f994daba536902f30b1bebc2235099c8b8a039d8b37d9d27d4827e0ca"

root="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# copy <source dir> <destination dir> <files...>: copies the files (paths relative to the source) keeping their paths.
copy() {
    copy_from="$1"; copy_to="$2"; shift 2
    for copy_file; do
        mkdir -p "$copy_to/$(dirname "$copy_file")"
        cp "$copy_from/$copy_file" "$copy_to/$copy_file"
    done
}

# ---------------------------------------------------------------- WavPack (C, BSD-3-Clause)
# The decoder only: no encoder (pack*.c, write_words.c, extra*.c), no assembly (x86 only anyway), no threads.
# Legacy (< 4.0) files and DSD are in. open_filename.c is the library's own FILE* reader.
git -c advice.detachedHead=false clone -q --depth 1 --branch "$wavpack_tag" https://github.com/dbry/WavPack.git "$tmp/wavpack"
wavpack_commit="$(git -C "$tmp/wavpack" rev-parse HEAD)"
rm -rf "$root/wavpack"
copy "$tmp/wavpack" "$root/wavpack" \
    COPYING include/wavpack.h \
    src/common_utils.c src/decorr_utils.c src/entropy_utils.c src/open_filename.c src/open_legacy.c src/open_raw.c \
    src/open_utils.c src/read_words.c src/tag_utils.c src/tags.c src/unpack.c src/unpack_dsd.c src/unpack_floats.c \
    src/unpack_seek.c src/unpack_utils.c src/unpack3.c src/unpack3_open.c src/unpack3_seek.c \
    src/decorr_tables.h src/unpack3.h src/wavpack_local.h src/wavpack_version.h

# ---------------------------------------------------------------- Monkey's Audio (C++, BSD-3-Clause)
# The SDK minus the console tool, the DLL, the Windows projects and the SIMD filters of other architectures. The
# encoder can't be left out: the SDK's All.h always defines APE_SUPPORT_COMPRESS, so MACLib.cpp refers to it.
curl -fsSL -o "$tmp/sdk.zip" "https://monkeysaudio.com/files/MAC_${monkeys_version}_SDK.zip"
actual="$(shasum -a 256 "$tmp/sdk.zip" | cut -d ' ' -f 1)"
if [ "$actual" != "$monkeys_sha256" ]; then
    echo "error: MAC_${monkeys_version}_SDK.zip has sha256 $actual, expected $monkeys_sha256" >&2
    echo "       (a new version, or the file was replaced upstream: check it, then update monkeys_sha256)" >&2
    exit 1
fi
mkdir "$tmp/sdk"
unzip -q "$tmp/sdk.zip" -d "$tmp/sdk"
monkeys="$root/monkeys-audio"
rm -rf "$monkeys/Source"
mkdir -p "$monkeys"
cp "$tmp/sdk/License.txt" "$monkeys/License.txt"
(
    cd "$tmp/sdk"
    # Every header (an unused one costs nothing), and the sources the library is built from (CMakeLists.txt: the
    # shared and library sources, StdLibFileIO for non-Windows, the NEON and x86 filters).
    find Source/Shared Source/MACLib -name '*.h' ! -name 'MFC*' ! -name 'GDIBitmapPtr.h' ! -name 'WinFileIO.h'
    printf '%s\n' \
        Source/Shared/BufferIO.cpp Source/Shared/CharacterHelper.cpp Source/Shared/CircleBuffer.cpp \
        Source/Shared/CPUFeatures.cpp Source/Shared/CRC.cpp Source/Shared/GlobalFunctions.cpp Source/Shared/MemoryIO.cpp \
        Source/Shared/Semaphore.cpp Source/Shared/StdLibFileIO.cpp Source/Shared/Thread.cpp Source/Shared/WholeFileIO.cpp
    find Source/MACLib -name '*.cpp' ! -name 'NNFilterAltiVec.cpp' ! -name 'NNFilterRVV.cpp'
) | sort > "$tmp/monkeys-files"
# shellcheck disable=SC2046
copy "$tmp/sdk" "$monkeys" $(cat "$tmp/monkeys-files")

cat > "$root/UPSTREAM" <<EOF
# Written by vendor/update.sh, don't edit.
wavpack $wavpack_tag https://github.com/dbry/WavPack commit $wavpack_commit
monkeys-audio $monkeys_version https://monkeysaudio.com/files/MAC_${monkeys_version}_SDK.zip sha256 $monkeys_sha256
EOF
echo "vendor/: WavPack $wavpack_tag ($wavpack_commit), Monkey's Audio SDK $monkeys_version"
