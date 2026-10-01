#!/bin/sh
# Builds and (optionally) runs the playlist view PoC.
#   ./build.sh        - build only
#   ./build.sh run    - build and run
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -parse-as-library \
    -target arm64-apple-macos15.4 \
    -o build/playlist-view \
    Model.swift VirtualPlaylistView.swift App.swift
echo "built: $(pwd)/build/playlist-view"
if [ "$1" = "run" ]; then
    exec build/playlist-view
fi
