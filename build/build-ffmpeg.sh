#!/bin/bash

loc="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$loc/ffmpeg/ffmpeg" ] && [ -f "$loc/ffmpeg/ffprobe" ] && [ "$1" != "-f" ]; then
    cp -f "$loc/ffmpeg/ffmpeg" "$loc/Contents/Tools/ffmpeg-ichm"
    cp -f "$loc/ffmpeg/ffprobe" "$loc/Contents/Tools/ffprobe-ichm"
    exit
fi

if [ -d "$loc/ffmpeg" ]; then
    rm -rf "$loc/ffmpeg"
fi

mkdir "$loc/ffmpeg"

( exec &> >(while read -r line; do echo "$(date +"[%Y-%m-%d %H:%M:%S]") $line"; done;) #_Date to Every Line

tput bold ; echo "adam | 2014 < 2021-08-26" ; tput sgr0
tput bold ; echo "Download and Build Last Static FFmpeg" ; tput sgr0
tput bold ; echo "macOS 10.12 < 11 Build Compatibility" ; tput sgr0
echo "macOS $(sw_vers -productVersion) | $(system_profiler SPHardwareDataType | grep Memory | cut -d ':' -f2) | $(system_profiler SPHardwareDataType | grep Cores: | cut -d ':' -f2) Cores | $(system_profiler SPHardwareDataType | grep Speed | cut -d ':' -f2)" ; sleep 2

#_ Check Xcode CLI Install
tput bold ; echo ; echo '♻️  ' Check Xcode CLI Install ; tput sgr0
if xcode-select -v | grep version ; then tput sgr0 ; echo "Xcode CLI AllReady Installed" ; else tput bold ; echo "Xcode CLI Install" ; tput sgr0 ; xcode-select --install
sleep 1
while pgrep 'Install Command Line Developer Tools' >/dev/null ; do sleep 5 ; done
if xcode-select -v | grep version ; then tput sgr0 ; echo "Xcode CLI Was SucessFully Installed" ; else tput bold ; echo "Xcode CLI Was NOT Installed" ; tput sgr0 ; exit ; fi ; fi

#_ Check Homebrew Install
tput bold ; echo ; echo '♻️  ' Check Homebrew Install ; tput sgr0 ; sleep 2
if ls /usr/local/bin/brew >/dev/null ; then tput sgr0 ; echo "HomeBrew AllReady Installed" ; else tput bold ; echo "Installing HomeBrew" ; tput sgr0 ; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ; fi

#_ Check Homebrew Config
tput bold ; echo ; echo '♻️  ' Check Homebrew Config ; tput sgr0 ; sleep 2
brew install git wget cmake autoconf automake nasm libtool pkg-config rtmpdump
brew uninstall --ignore-dependencies libx11

#_ Check Miminum Requirement Build Time
Time="$(echo 'obase=60;'$SECONDS | bc | sed 's/ /:/g' | cut -c 2-)"
tput bold ; echo ; echo '⏱  ' Miminum Requirement Build in "$Time"s ; tput sgr0 ; sleep 2

#_ Eject RamDisk
if df | grep RamDisk > /dev/null ; then tput bold ; echo ; echo '⏏  ' Eject RamDisk ; tput sgr0 ; fi
if df | grep RamDisk > /dev/null ; then diskutil eject RamDisk ; sleep 2 ; fi

#_ Made RamDisk
tput bold ; echo ; echo '💾 ' Made 1Go RamDisk ; tput sgr0
diskutil erasevolume HFS+ 'RamDisk' $(hdiutil attach -nomount ram://2097152)
sleep 1

#_ CPU & PATHS & ERROR
THREADS=$(sysctl -n hw.ncpu)
TARGET="/Volumes/RamDisk/sw"
CMPL="/Volumes/RamDisk/compile"
export PATH="${TARGET}"/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/include:/usr/local/opt:/usr/local/Cellar:/usr/local/lib:/usr/local/share:/usr/local/etc
mdutil -i off /Volumes/RamDisk

#_ Make RamDisk Directories
mkdir ${TARGET}
mkdir ${CMPL}



#-> BASE
tput bold ; echo ; echo ; echo '⚙️  ' Base Builds ; tput sgr0

set -o errexit

#_ pkg-config
LastVersion=$(wget --no-check-certificate 'https://pkg-config.freedesktop.org/releases/' -O- -q | grep -Eo 'pkg-config-0.29[0-9\.]+\.tar.gz' | tail -1)
tput bold ; echo ; echo '📍 ' "$LastVersion" ; tput sgr0 ; sleep 2
cd ${CMPL}
wget --no-check-certificate 'https://pkg-config.freedesktop.org/releases/'"$LastVersion"
tar -zxvf pkg-config-*
cd pkg-config-*/
./configure --prefix=${TARGET} --disable-debug --disable-host-tool --with-internal-glib
make -j "$THREADS" && make check && make install
rm -fr /Volumes/RamDisk/compile/*

#-> AUDIO
tput bold ; echo ; echo ; echo '⚙️  ' Audio Builds ; tput sgr0

#_ opus - Replace speex
#LastVersion=$(wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/opus/ -O- -q | grep -Eo 'opus-1.[0-9\.]+\.[0-9\.]+\.tar.gz' | tail -1)
#tput bold ; echo ; echo '📍 ' "$LastVersion" ; tput sgr0 ; sleep 2
#cd ${CMPL}
#wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/opus/"$LastVersion"
#tar -zxvf opus-*
#cd opus-*/
#./configure --prefix=${TARGET} --disable-shared --enable-static
#make -j "$THREADS" && make install
#rm -fr /Volumes/RamDisk/compile/*

#_ ogg
#LastVersion=$(wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/ogg/ -O- -q | grep -Eo 'libogg-[0-9\.]+\.tar.gz' | tail -1)
#tput bold ; echo ; echo '📍 ' "$LastVersion" ; tput sgr0 ; sleep 2
#cd ${CMPL}
#wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/ogg/"$LastVersion"
#tar -zxvf libogg-*
#cd libogg-*/
#./configure --prefix=${TARGET} --disable-shared --enable-static --disable-dependency-tracking
#make -j "$THREADS" && make install
#rm -fr /Volumes/RamDisk/compile/*

#_ vorbis
#LastVersion=$(wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/vorbis/ -O- -q | grep -Eo 'libvorbis-[0-9\.]+\.tar.gz' | tail -1)
#tput bold ; echo ; echo '📍 ' "$LastVersion" ; tput sgr0 ; sleep 2
#cd ${CMPL}
#wget --no-check-certificate https://ftp.osuosl.org/pub/xiph/releases/vorbis/"$LastVersion"
#tar -zxvf libvorbis-*
#cd libvorbis-*/
#./configure --prefix=${TARGET} --with-ogg-libraries=${TARGET}/lib --with-ogg-includes=/Volumes/RamDisk/sw/include/ --enable-static --disable-shared
#make -j "$THREADS" && make install
#rm -fr /Volumes/RamDisk/compile/*

#-> FFmpeg Check
tput bold ; echo ; echo ; echo '⚙️  ' FFmpeg Build ; tput sgr0

#_ Purge .dylib
tput bold ; echo ; echo '💢 ' Purge .dylib ; tput sgr0 ; sleep 2
rm -vfr $TARGET/lib/*.dylib
rm -vfr /usr/local/opt/libx11/lib/libX11.6.dylib

#_ Flags
tput bold ; echo ; echo '🚩 ' Define FLAGS ; tput sgr0 ; sleep 2
export LDFLAGS="-L${TARGET}/lib"
export CPPFLAGS="-I${TARGET}/include"
export CFLAGS="-I${TARGET}/include -fno-stack-check"

#_ FFmpeg Build
tput bold ; echo ; echo '📍 ' FFmpeg git ; tput sgr0 ; sleep 2

FFMPEG_CONFIGURE_FLAGS=(
    --disable-shared
    --enable-static

    --disable-doc
    --disable-debug
    --disable-avdevice
    --disable-swscale
    --disable-programs
    --enable-rdft
    --enable-ffmpeg
    --enable-ffprobe
    --disable-network
    --disable-muxers
    --disable-demuxers
    --disable-zlib
    --disable-bzlib
    --disable-iconv
    --disable-bsfs
    --disable-filters
    --disable-parsers
    --disable-indevs
    --disable-outdevs
    --disable-encoders
    --disable-decoders
    --disable-hwaccels
    --disable-nvenc
    --disable-xvmc
    --disable-videotoolbox
    --disable-audiotoolbox
    --disable-sdl2
    --disable-xlib
    --disable-lzma

    --disable-filters
    --enable-filter=aformat
    --enable-filter=aresample
    --enable-filter=anull
    --enable-filter=atrim
    --enable-filter=format
    --enable-filter=null
    --enable-filter=setpts
    --enable-filter=trim

    --disable-protocols
    --enable-protocol=file
    --enable-protocol=pipe

    --enable-demuxer=aac
    --enable-demuxer=ac3
    --enable-demuxer=aiff
    --enable-demuxer=ape
    --enable-demuxer=flac
    --enable-demuxer=ogg
    --enable-demuxer=wv
    --enable-demuxer=dsf
    --enable-demuxer=mp3
    --enable-demuxer=mov
    --enable-demuxer=image2

    --enable-muxer=pcm_f64be
    --enable-muxer=pcm_f64le
    --enable-muxer=pcm_f32be
    --enable-muxer=pcm_f32le
    --enable-muxer=pcm_s32be
    --enable-muxer=pcm_s32le
    --enable-muxer=pcm_s24be
    --enable-muxer=pcm_s24le
    --enable-muxer=pcm_s16be
    --enable-muxer=pcm_s16le
    --enable-muxer=pcm_s8
    --enable-muxer=pcm_u32be
    --enable-muxer=pcm_u32le
    --enable-muxer=pcm_u24be
    --enable-muxer=pcm_u24le
    --enable-muxer=pcm_u16be
    --enable-muxer=pcm_u16le
    --enable-muxer=pcm_u8
    --enable-muxer=wav
    --enable-muxer=image2

    --enable-decoder=ape
    --enable-decoder=flac
    --enable-decoder=vorbis
    --enable-decoder=wavpack

    --enable-encoder=pcm_s16le
    --enable-encoder=pcm_s16le_planar
    --enable-encoder=pcm_s24le
    --enable-encoder=pcm_s24le_planar
    --enable-encoder=pcm_s32le
    --enable-encoder=pcm_s32le_planar
    --enable-encoder=pcm_u8
    --enable-encoder=pcm_u16le
    --enable-encoder=pcm_u24le
    --enable-encoder=pcm_u32le
    --enable-encoder=mjpeg

    --extra-version="ichm"
    --extra-cflags="-fno-stack-check"
    --arch=x86_64
    --cc=/usr/bin/clang
    --enable-pthreads
    --enable-postproc
    --enable-runtime-cpudetect
    --pkg_config='pkg-config --static'
    --prefix=${TARGET}
)

cd ${CMPL}
git clone --depth 1 --branch n4.4 git://git.ffmpeg.org/ffmpeg.git
cd ffmpe*/
./configure "${FFMPEG_CONFIGURE_FLAGS[@]}"
make -j "$THREADS" && make install

#_ Check Static
tput bold ; echo ; echo '♻️  ' Check Static FFmpeg ; tput sgr0 ; sleep 2
if otool -L /Volumes/RamDisk/sw/bin/ffmpeg | grep /usr/local
then echo FFmpeg build Not Static
#open ~/Library/Logs/adam-FFmpeg-Static.log
exit 1
else echo FFmpeg build Static, Have Fun
fi
cp -f /Volumes/RamDisk/sw/bin/ffmpeg "$loc/ffmpeg/ffmpeg"
cp -f /Volumes/RamDisk/sw/bin/ffprobe "$loc/ffmpeg/ffprobe"
strip "$loc/ffmpeg/ffmpeg"
strip "$loc/ffmpeg/ffprobe"
cp -f "$loc/ffmpeg/ffmpeg" "$loc/Contents/Tools/ffmpeg-ichm"
cp -f "$loc/ffmpeg/ffprobe" "$loc/Contents/Tools/ffprobe-ichm"

#_ Tests
"$loc/build-ffmpeg-test.sh"

#_ End Time
Time="$(echo 'obase=60;'$SECONDS | bc | sed 's/ /:/g' | cut -c 2-)"
tput bold ; echo ; echo '⏱  ' End in "$Time"s ; tput sgr0
) 2>&1 | tee "$HOME/Library/Logs/adam-FFmpeg-Static.log"
