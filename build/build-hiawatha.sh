#!/bin/bash

set -e

repo="https://gitlab.com/hsleisink/hiawatha.git"
tag="v11.0"

loc="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$loc"

if [ ! -f hiawatha/build/hiawatha ] || [ "$1" == "-f" ]; then
    if [ ! -d hiawatha ] ; then
        git clone --depth 1 --branch "${tag}" "${repo}"
    fi

    cd hiawatha

    if [ -d  ]; then
        rm -rf build
    fi

    mkdir build
    cd build

    cmake .. \
      -DENABLE_CACHE=off \
      -DENABLE_MONITOR=off \
      -DENABLE_RPROXY=off \
      -DENABLE_TLS=off \
      -DENABLE_TOMAHAWK=off \
      -DENABLE_TOOLKIT=off \
      -DENABLE_XSLT=off \
      -DUSE_SYSTEM_MBEDTLS=off

    make hiawatha
    strip hiawatha

    cd ../..
fi

cp -f hiawatha/build/hiawatha Contents/Web/Server/hiawatha-ichm
