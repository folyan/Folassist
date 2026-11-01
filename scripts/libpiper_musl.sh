#!/bin/sh
set -eux
apk add --no-cache build-base cmake ninja git pkgconf onnxruntime
VER=$(apk list -I onnxruntime | awk '{print $1}' | sed 's/^onnxruntime-//; s/-r[0-9]*$//')
mkdir -p ort/lib ort/include
cp -P /usr/lib/libonnxruntime*.so* ort/lib/
ln -sf libonnxruntime.so.1 ort/lib/libonnxruntime.so
git clone --depth 1 --filter=blob:none --sparse --branch "v$VER" https://github.com/microsoft/onnxruntime src-ort
git -C src-ort sparse-checkout set include
cp src-ort/include/onnxruntime/core/session/*.h ort/include/
git clone --depth 1 https://github.com/OHF-voice/piper1-gpl.git piper
cmake -S piper/libpiper -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/prefix" -DONNXRUNTIME_DIR="$PWD/ort"
cmake --build build -j"$(nproc)"
cmake --install build
