#!/bin/sh
# Builds the tag-parsing PoC.
#   ./build.sh            - build app + bench
#   ./build.sh run        - build and run the SwiftUI harness
#   ./build.sh app|bench  - build only that target
set -e
cd "$(dirname "$0")"
mkdir -p build
FLAGS="-O -parse-as-library -target arm64-apple-macos15.4"
LIB="TagReader/TagModels.swift TagReader/TagBackends.swift TagReader/TagReader.swift TagReader/AudioFileScanner.swift TagReader/ArtworkFinder.swift"

target="${1:-all}"
if [ "$target" = "bench" ] || [ "$target" = "all" ]; then
    swiftc $FLAGS -o build/bench $LIB Bench/Bench.swift
    echo "built: $(pwd)/build/bench"
fi
if [ "$target" = "app" ] || [ "$target" = "all" ] || [ "$target" = "run" ]; then
    swiftc $FLAGS -o build/tag-parsing $LIB App/App.swift
    echo "built: $(pwd)/build/tag-parsing"
fi
if [ "$target" = "run" ]; then
    exec build/tag-parsing
fi
