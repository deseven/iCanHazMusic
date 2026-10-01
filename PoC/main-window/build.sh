#!/bin/sh
# Builds and (optionally) runs the main window PoC.
#   ./build.sh        - build only
#   ./build.sh run    - build and run
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -parse-as-library \
    -target arm64-apple-macos15.4 \
    -o build/main-window \
    PlaybackBlock.swift MainWindow.swift App.swift
echo "built: $(pwd)/build/main-window"
if [ "$1" = "run" ]; then
    exec build/main-window
fi
