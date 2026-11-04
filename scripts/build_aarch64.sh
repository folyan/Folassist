#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || { command -v bash >/dev/null 2>&1 || { command -v apk >/dev/null && apk add --no-cache bash; } || exec sh "$0" "$@"; exec bash "$0" "$@"; }
set -euxo pipefail

ROOT="$(pwd)"
B="$ROOT/build"
JOBS="$(nproc)"
mkdir -p "$B" "$ROOT/out" "$ROOT/Folclient/vendor/lib"

if command -v apk >/dev/null 2>&1; then
  TARGET="aarch64-linux-musl"
  OUT_NAME="folclient-aarch64-musl"
  apk add --no-cache build-base cmake ninja git wget xz bzip2 patch zlib-dev pkgconf linux-headers file coreutils bash
else
  TARGET="aarch64-linux-gnu.2.33"
  OUT_NAME="folclient-aarch64-glibc"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends build-essential gcc g++ cmake ninja-build python3 git wget ca-certificates xz-utils bzip2 patch zlib1g-dev pkg-config file
fi

export CC=gcc CXX=g++ AR=ar RANLIB=ranlib STRIP=strip

cd "$B"
if [ ! -f "$B/zig-aarch64-linux-0.17.0/zig" ]; then
  wget -q https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz -O zig.tar.xz
  tar -xJf zig.tar.xz
fi
ZIG="$B/zig-aarch64-linux-0.17.0/zig"

if [ ! -f "$B/alsa-root/usr/lib/libasound.a" ]; then
  cd "$B"
  wget -q https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.10.tar.bz2 -O alsa-lib.tar.bz2
  tar -xjf alsa-lib.tar.bz2
  cd alsa-lib-1.2.10
  ./configure --prefix=/usr --sysconfdir=/etc --enable-static --disable-shared \
    --disable-python --disable-topology CFLAGS="-Os"
  make -j"$JOBS"
  make DESTDIR="$B/alsa-root" install
fi
cp "$B/alsa-root/usr/lib/libasound.a" "$ROOT/Folclient/vendor/lib/"

if [ ! -f "$B/libsherpa_fat.a" ]; then
  cd "$B"
  if [ ! -d sherpa-onnx ]; then
    git clone --depth 1 -b v2.0.1 https://github.com/k2-fsa/sherpa-onnx || git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx
  fi
  cd sherpa-onnx
  mkdir -p build-static
  cd build-static
  cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$B/sherpa-install" \
    -DCMAKE_CXX_FLAGS="-include cstdint -include stdint.h -Os" \
    -DCMAKE_C_FLAGS="-Os" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_TTS=OFF \
    -DSHERPA_ONNX_ENABLE_AUDIO_TAGGING=OFF \
    -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
    -DSHERPA_ONNX_ENABLE_KEYWORD_SPEAKER_DIARIZATION=OFF \
    -DSHERPA_ONNX_ENABLE_PUNCTUATION=OFF \
    -DSHERPA_ONNX_ENABLE_SPOKEN_LANGUAGE_IDENTIFICATION=OFF \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF \
    ..
  ninja install

  find "$B/sherpa-onnx/build-static" -name "libonnxruntime*.a" -exec cp -f {} "$B/sherpa-install/lib/" \; 2>/dev/null || true

  cd "$B/sherpa-install/lib"
  {
    echo "create $B/libsherpa_fat.a"
    for a in *.a; do
      [ -f "$a" ] && echo "addlib $PWD/$a"
    done
    echo "save"
    echo "end"
  } | $AR -M
  $RANLIB "$B/libsherpa_fat.a"
  $STRIP --strip-debug "$B/libsherpa_fat.a"
fi

cp "$B/libsherpa_fat.a" "$ROOT/Folclient/vendor/lib/"
cp "$B/libsherpa_fat.a" "$ROOT/out/"
mkdir -p "$ROOT/Folclient/vendor/lib/sherpa-onnx/c-api"
cp "$B/sherpa-install/include/sherpa-onnx/c-api/c-api.h" "$ROOT/Folclient/vendor/lib/sherpa-onnx/c-api/"
cp "$B/sherpa-install/include/sherpa-onnx/c-api/c-api.h" "$ROOT/Folclient/vendor/lib/"

EXTRA="$($CXX -print-file-name=libstdc++.a),$($CC -print-libgcc-file-name),$($CC -print-file-name=libgcc_eh.a)"

cd "$ROOT/Folclient"
"$ZIG" build -Doptimize=ReleaseSmall \
  -Dtarget="$TARGET" \
  -Dlibs="$ROOT/Folclient/vendor/lib" \
  -Dinclude="$B/alsa-root/usr/include" \
  -Dextra-libs="$EXTRA"

cp zig-out/bin/folclient "$ROOT/out/$OUT_NAME"
nm -C -S --radix=d "$ROOT/Folclient/vendor/lib/libsherpa_fat.a" 2>/dev/null | awk 'NF>=4 && $2+0>0 {split($4,a,"::"); s[a[1]]+=$2} END{for(k in s) print s[k], k}' | sort -rn | head -60 > "$ROOT/out/size-report-$OUT_NAME.txt" || true
$STRIP --strip-all "$ROOT/out/$OUT_NAME"
file "$ROOT/out/$OUT_NAME" || true
cp zig-out/bin/folwatchdog "$ROOT/out/${OUT_NAME/folclient/folwatchdog}"
$STRIP --strip-all "$ROOT/out/${OUT_NAME/folclient/folwatchdog}"
