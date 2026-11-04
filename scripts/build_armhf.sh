#!/usr/bin/env bash
set -euxo pipefail

ROOT="$(pwd)"
B="$ROOT/build"
T=arm-linux-gnueabihf
ARM_FPU="${ARM_FPU:-neon}"
ARCH="-march=armv7-a -mfpu=$ARM_FPU -mfloat-abi=hard"
JOBS="$(nproc)"
mkdir -p "$B" "$ROOT/out" "$ROOT/Folclient/vendor/lib"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  gcc-$T g++-$T gcc g++ make cmake ninja-build python3 \
  git wget ca-certificates xz-utils bzip2 patch zlib1g-dev pkg-config file

export CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib STRIP=$T-strip

cd "$B"
if [ ! -f "$B/zig-x86_64-linux-0.17.0/zig" ]; then
  wget -q https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz -O zig.tar.xz
  tar -xJf zig.tar.xz
fi
ZIG="$B/zig-x86_64-linux-0.17.0/zig"

# 1. alsa-lib (статический)
if [ ! -f "$B/alsa-root/usr/lib/libasound.a" ]; then
  cd "$B"
  wget -q https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.10.tar.bz2 -O alsa-lib.tar.bz2
  tar -xjf alsa-lib.tar.bz2
  cd alsa-lib-1.2.10
  ./configure --host=$T --prefix=/usr --sysconfdir=/etc --enable-static --disable-shared \
    --disable-python --disable-topology CFLAGS="-Os $ARCH"
  make -j"$JOBS"
  make DESTDIR="$B/alsa-root" install
fi
cp "$B/alsa-root/usr/lib/libasound.a" "$ROOT/Folclient/vendor/lib/"

# 2. sherpa-onnx (статический C API v2.0.1)
if [ ! -f "$B/libsherpa_fat.a" ]; then
  cd "$B"
  if [ ! -d sherpa-onnx ]; then
    git clone --depth 1 -b v2.0.1 https://github.com/k2-fsa/sherpa-onnx || git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx
  fi
  cd sherpa-onnx
  mkdir -p build-static
  cd build-static
  cmake -G Ninja \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_C_COMPILER=$CC \
    -DCMAKE_CXX_COMPILER=$CXX \
    -DCMAKE_C_FLAGS="-Os $ARCH" \
    -DCMAKE_CXX_FLAGS="-Os $ARCH -include cstdint -include stdint.h" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$B/sherpa-install" \
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
  -Dtarget=$T.2.33 \
  -Dlibs="$ROOT/Folclient/vendor/lib" \
  -Dinclude="$B/alsa-root/usr/include" \
  -Dextra-libs="$EXTRA"

cp zig-out/bin/folclient "$ROOT/out/folclient-armhf"
nm -C -S --radix=d "$ROOT/Folclient/vendor/lib/libsherpa_fat.a" 2>/dev/null | awk 'NF>=4 && $2+0>0 {split($4,a,"::"); s[a[1]]+=$2} END{for(k in s) print s[k], k}' | sort -rn | head -60 > "$ROOT/out/size-report-folclient-armhf.txt" || true
$STRIP --strip-all "$ROOT/out/folclient-armhf"
file "$ROOT/out/folclient-armhf" || true
cp zig-out/bin/folwatchdog "$ROOT/out/folwatchdog-armhf"
$STRIP --strip-all "$ROOT/out/folwatchdog-armhf"
