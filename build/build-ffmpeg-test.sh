#!/bin/bash

noColor='\033[0m'
greenColor='\033[32m'
redColor='\033[31m'

loc="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$loc"

if [ ! -d ffmpeg-test-files ]; then
    echo "no test files - skipping tests"
    exit
fi

mp3_testfile="ffmpeg-test-files/test.mp3"
flac_testfile="ffmpeg-test-files/test.flac"
oga_testfile="ffmpeg-test-files/test.oga"
ogg_testfile="ffmpeg-test-files/test.ogg"
wv_testfile="ffmpeg-test-files/test.wv"
m4a_testfile="ffmpeg-test-files/test.m4a"
ape_testfile="ffmpeg-test-files/test.ape"

temp_file="ffmpeg-test-files/test.wav"

function ffmpeg_test() {
    if [ -f "$test_file" ]; then
        rm -f "$test_file"
    fi
    failed_info=""
    ffprobe_output=$(ffmpeg/ffprobe -v 0 -print_format json -show_format -show_streams "$1" | grep -i "artist")
    #echo "$ffprobe_output"
    if [ -z "$ffprobe_output" ]; then
        failed_info=" tags"
    fi
    if [ "$2" == "full" ]; then
        ffmpeg/ffmpeg -v 0 -i "$1" -y -map_metadata -1 "$temp_file"
        file_info=$(file "$temp_file" | grep "WAVE audio")
        if [ -z "$file_info" ]; then
            failed_info="${failed_info} decode"
        fi
    fi
    if [ ! -z "$failed_info" ]; then
        echo -e "${redColor}FAILED${failed_info}${noColor}"
    else
        echo -e "${greenColor}OK${noColor}"
    fi
}

echo -n "testing m4a file [tags]: "
if [ -f "$m4a_testfile" ]; then    
    ffmpeg_test "$m4a_testfile" tags
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing mp3 file [tags]: "
if [ -f "$mp3_testfile" ]; then    
    ffmpeg_test "$mp3_testfile" tags
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing flac file [tags,decode]: "
if [ -f "$flac_testfile" ]; then    
    ffmpeg_test "$flac_testfile" full
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing oga file [tags,decode]: "
if [ -f "$oga_testfile" ]; then    
    ffmpeg_test "$oga_testfile" full
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing ogg file [tags,decode]: "
if [ -f "$ogg_testfile" ]; then    
    ffmpeg_test "$ogg_testfile" full
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing wv file [tags,decode]: "
if [ -f "$wv_testfile" ]; then    
    ffmpeg_test "$wv_testfile" full
else
    echo "SKIPPED (no test file)"
fi

echo -n "testing ape file [tags,decode]: "
if [ -f "$ape_testfile" ]; then    
    ffmpeg_test "$ape_testfile" full
else
    echo "SKIPPED (no test file)"
fi