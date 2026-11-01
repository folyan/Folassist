# Сборка клиента

Нужен `Folclient/vendor/translate-c` (пакет из build.zig.zon) и `Folclient/vendor/lib/` с
`libvosk_fat.a`, `libasound.a`, `vosk_api.h`.

## aarch64, Alpine (musl)
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    cd Folclient
    /opt/zig-aarch64-linux-0.17.0/zig build -Doptimize=ReleaseSmall \
      -Dextra-libs=/usr/lib/libstdc++.a,/usr/lib/libgfortran.a,/usr/lib/gcc/aarch64-alpine-linux-musl/15.2.0/libgcc.a

## armhf, glibc 2.30 (GitHub Actions)
Actions -> build-armhf -> Run workflow. Скрипт: scripts/build_armhf.sh.
FPU по умолчанию `neon` (VFPv3+NEON); для vfpv4 задай ARM_FPU=neon-vfpv4 в скрипте.
Результат в artifacts: folclient-armhf и libvosk_fat.a.
