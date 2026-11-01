#!/usr/bin/env bash
# Кросс-сборка folclient под armhf (glibc). Запускать из корня репозитория внутри ubuntu:20.04.
# Результат: out/folclient и out/libvosk_fat.a
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
  gcc-$T g++-$T gfortran-$T gcc g++ make autoconf automake libtool cmake python3 \
  git wget ca-certificates xz-utils bzip2 patch zlib1g-dev pkg-config

export CC=$T-gcc CXX=$T-g++ FC=$T-gfortran AR=$T-ar RANLIB=$T-ranlib STRIP=$T-strip

cd "$B"
wget -q https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz -O zig.tar.xz
tar -xJf zig.tar.xz
ZIG="$B/zig-x86_64-linux-0.17.0/zig"

[ -d vosk-api ] || git clone --depth 1 https://github.com/alphacep/vosk-api
[ -d kaldi ]    || git clone --depth 1 -b vosk --single-branch https://github.com/alphacep/kaldi
[ -d OpenBLAS ] || git clone --depth 1 -b v0.3.20 --single-branch https://github.com/xianyi/OpenBLAS
[ -d openfst ]  || git clone --depth 1 https://github.com/alphacep/openfst

# --- OpenBLAS + LAPACK
cd "$B/OpenBLAS"
OB_ARGS=(TARGET=ARMV7 HOSTCC=gcc CC="$CC" FC="$FC" AR="$AR" RANLIB="$RANLIB"
  DYNAMIC_ARCH=0 NO_SHARED=1 USE_LOCKING=1 USE_THREAD=0
  CFLAGS="-Os $ARCH -Wno-error=implicit-function-declaration" FFLAGS="-Os $ARCH")
make -j"$JOBS" "${OB_ARGS[@]}" libs netlib
make "${OB_ARGS[@]}" PREFIX="$B/openblas-install" install
OPENBLAS_A="$(ls "$B"/OpenBLAS/libopenblas_*.a | head -1)"

$CC -O2 -fPIC $ARCH -c "$ROOT/scripts/shim_dotsub.c" -o "$B/shim.o"
$AR rcs "$B/shim.a" "$B/shim.o"

# --- OpenFST
cd "$B/openfst"
autoreconf -i
./configure --host=$T --prefix="$B/openfst-install" --enable-static --disable-shared \
  --enable-ngram-fsts --enable-lookahead-fsts --with-pic \
  CXXFLAGS="-Os $ARCH" CFLAGS="-Os $ARCH"
make -j"$JOBS"
make install
cp -r "$B/openfst-install/include" "$B/openfst/"
mkdir -p "$B/openfst/lib" && cp "$B/openfst-install/lib/"*.a "$B/openfst/lib/"

# --- Kaldi
mkdir -p "$B/openblas-install/lib"
cp "$OPENBLAS_A" "$B/openblas-install/lib/libopenblas.a"
ln -sf libopenblas.a "$B/openblas-install/lib/libopenblas.so"
cd "$B/kaldi/src"
./configure --static --mathlib=OPENBLAS --use-cuda=no \
  --openblas-root="$B/openblas-install" --fst-root="$B/openfst"
sed -i 's/-msse2\?//g; s/-mavx[^ ]*//g; s/-mfma//g; s/-O[0-9]/-Os/g' kaldi.mk
sed -i "s|^CXXFLAGS = |CXXFLAGS = $ARCH |" kaldi.mk
MODS="online2 decoder ivector gmm tree feat lat lm rnnlm nnet3 matrix fstext util base hmm cudamatrix transform"
nice -n 19 make -j"$JOBS" $MODS

# флаги компиляции Kaldi для файлов Vosk
printf 'include kaldi.mk\nprint:\n\t@echo $(CXXFLAGS)\n' > "$B/pf.mk"
KFLAGS="$(make -s -f "$B/pf.mk" print)"

# --- Vosk
cd "$B/vosk-api/src"
for f in recognizer language_model model spk_model vosk_api postprocessor; do
  [ -f "$f.cc" ] || continue
  $CXX -std=c++17 -fPIC $KFLAGS -DFST_NO_DYNAMIC_LINKING -I. -I"$B/kaldi/src" -c "$f.cc" -o "$f.o"
done
$AR rcs libvosk_base.a recognizer.o model.o vosk_api.o postprocessor.o $( [ -f language_model.o ] && echo language_model.o ) $( [ -f spk_model.o ] && echo spk_model.o )

{
  echo "create $B/libvosk_fat.a"
  echo "addlib $B/vosk-api/src/libvosk_base.a"
  for m in $MODS; do echo "addlib $B/kaldi/src/$m/kaldi-$m.a"; done
  echo "addlib $B/openfst-install/lib/libfst.a"
  echo "addlib $B/openfst-install/lib/libfstngram.a"
  echo "addlib $OPENBLAS_A"
  echo "addlib $B/shim.a"
  echo "save"
  echo "end"
} | $AR -M
$RANLIB "$B/libvosk_fat.a"
$STRIP --strip-debug "$B/libvosk_fat.a"
cp "$B/libvosk_fat.a" "$ROOT/Folclient/vendor/lib/"
cp "$B/libvosk_fat.a" "$ROOT/out/"
cp "$B/vosk-api/src/vosk_api.h" "$ROOT/Folclient/vendor/lib/"

# --- libasound.a (статическая, конфиги читаются из /usr/share/alsa на устройстве)
cd "$B"
wget -q https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.10.tar.bz2 -O alsa-lib.tar.bz2
tar -xjf alsa-lib.tar.bz2
cd alsa-lib-1.2.10
./configure --host=$T --prefix=/usr --sysconfdir=/etc --enable-static --disable-shared \
  --disable-python --disable-topology CFLAGS="-Os $ARCH"
make -j"$JOBS"
make DESTDIR="$B/alsa-root" install
cp "$B/alsa-root/usr/lib/libasound.a" "$ROOT/Folclient/vendor/lib/"

# --- клиент
EXTRA="$($CXX -print-file-name=libstdc++.a),$($FC -print-file-name=libgfortran.a),$($CC -print-libgcc-file-name),$($CC -print-file-name=libgcc_eh.a)"
cd "$ROOT/Folclient"
"$ZIG" build -Doptimize=ReleaseSmall \
  -Dtarget=$T.2.30 \
  -Dlibs="$ROOT/Folclient/vendor/lib" \
  -Dinclude="$B/alsa-root/usr/include" \
  -Dextra-libs="$EXTRA"
cp zig-out/bin/folclient "$ROOT/out/folclient-armhf"
file "$ROOT/out/folclient-armhf" || true
