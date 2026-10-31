#!/bin/sh
# Spotify Soloist для Яндекс Станции 2 (aarch64) внутри debian:trixie.
#
# Soloist собран под glibc 2.41, а на колонке 32-битная система с glibc 2.30 и голым
# ALSA. Поэтому рядом кладём свой рантайм Debian и PulseAudio: Soloist сам подгружает
# libpulse.so.0 и играет в виртуальный выход, а soloist.sh переносит звук в ALSA.
#
# Результат — /out/soloist/{bin,lib,lib/pulse}, рассчитанный на /data/local/opt/soloist:
# у бинарников Debian интерпретатор .../lib/ld-linux-aarch64.so.1 и RUNPATH $ORIGIN/../lib.
# Сам soloist не правим и запускаем через загрузчик (bin/soloist — обёртка).
# Архив Soloist распространять нельзя, поэтому он скачивается при каждой сборке.
#
# Запуск (монтировать только скрипт и out — см. RUNBOOK):
#   docker run --rm --platform linux/arm64 -v "$PWD/soloist-build.sh:/work/soloist-build.sh:ro" \
#     -v "$PWD/out:/out" debian:trixie sh /work/soloist-build.sh
set -eu

PREFIX=/data/local/opt/soloist
OUT=/out/soloist

echo "=== deps ==="
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends curl ca-certificates libatomic1 patchelf \
  pulseaudio pulseaudio-utils dpkg-dev gcc libc6-dev pkgconf libpulse-dev libltdl-dev >/dev/null 2>&1

echo "=== soloist ==="
rm -rf "$OUT" /tmp/s
mkdir -p "$OUT/bin" "$OUT/lib/pulse" /tmp/s
curl -sSL https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz | tar xz -C /tmp/s
cp /tmp/s/soloist "$OUT/bin/soloist.bin"
cp /tmp/s/CHANGELOG.md /tmp/s/THIRD_PARTY_LICENSES.txt "$OUT/"

echo "=== pulseaudio ==="
MODDIR=$(dirname "$(dpkg -L pulseaudio | grep '/module-null-sink.so$')")
for m in module-null-sink module-native-protocol-unix libprotocol-native; do
  cp "$MODDIR/$m.so" "$OUT/lib/pulse/"
done
for b in pulseaudio pactl parec; do cp "/usr/bin/$b" "$OUT/bin/"; done

# Виртуальный выход с «аппаратной» громкостью: пустой обработчик, и при flat-volumes
# (soloist.sh) PulseAudio не применяет громкость Soloist к звуку — её переносит на
# Master наблюдатель. Иначе каждый сдвиг ползунка давал всплеск: PulseAudio менял звук
# сразу, а Master догонял позже.
echo "=== module-null-sink с аппаратной громкостью ==="
(cd /tmp && apt-get source -qq pulseaudio >/dev/null 2>&1)
PASRC=$(ls -d /tmp/pulseaudio-*/)
M=$PASRC/src/modules/module-null-sink.c
awk '
  /^static void sink_update_requested_latency_cb/ && !done {
    print "static void sink_set_volume_cb(pa_sink *s) {\n}\n"; done = 1 }
  { print }
  /u->sink = pa_sink_new\(/ { getline; print
    print "    pa_sink_set_set_volume_callback(u->sink, sink_set_volume_cb);"
    print "    pa_sink_enable_decibel_volume(u->sink, true);" }
' "$M" > /tmp/null-sink.c
[ "$(grep -c 'sink_set_volume_cb' /tmp/null-sink.c)" -eq 2 ] || { echo "патч module-null-sink не лёг" >&2; exit 1; }
printf '%s\n' '#define PACKAGE "pulseaudio"' '#define PACKAGE_VERSION "17.0"' '#define _GNU_SOURCE 1' \
  '#define HAVE_ATOMIC_BUILTINS 1' '#define HAVE_PTHREAD 1' '#define HAVE_STDINT_H 1' > "$PASRC/config.h"
gcc -O2 -shared -fPIC -w -DHAVE_CONFIG_H -DPA_MODULE_NAME=module_null_sink -I"$PASRC" -I"$PASRC/src" \
  $(pkg-config --cflags libpulse) /tmp/null-sink.c -o "$OUT/lib/pulse/module-null-sink.so" \
  -L/usr/lib/aarch64-linux-gnu/pulseaudio -lpulsecore-17.0 -lpulsecommon-17.0 -lpulse

# Все зависимости (и то, что soloist подгружает сам: libpulse) — в lib/
LIBS=$( { ldd /tmp/s/soloist 2>/dev/null; ldd /usr/lib/aarch64-linux-gnu/libpulse.so.0
          for f in "$OUT"/bin/pulseaudio "$OUT"/bin/pactl "$OUT"/bin/parec "$OUT"/lib/pulse/*.so; do
            ldd "$f"; done; } | awk '/=> \// { print $3 }' | sort -u)
for l in $LIBS /usr/lib/aarch64-linux-gnu/libpulse.so.0 /lib/ld-linux-aarch64.so.1; do
  case "$l" in "$OUT"/*) continue ;; esac
  cp -L "$l" "$OUT/lib/"
done
cp /etc/ssl/certs/ca-certificates.crt "$OUT/lib/"

for b in pulseaudio pactl parec; do
  patchelf --set-interpreter "$PREFIX/lib/ld-linux-aarch64.so.1" --set-rpath '$ORIGIN/../lib' "$OUT/bin/$b"
done
for m in "$OUT"/lib/pulse/*.so; do patchelf --set-rpath '$ORIGIN:$ORIGIN/..' "$m"; done
# RUNPATH действует только на прямые зависимости, а иначе libm и прочие для библиотек
# нашлись бы в системном /lib колонки — 32-битные
for l in "$OUT"/lib/*.so*; do
  case "$l" in */ld-linux-*) continue ;; esac
  patchelf --set-rpath '$ORIGIN' "$l"
done

cat > "$OUT/bin/soloist" <<'EOF'
#!/bin/sh
# soloist под своим glibc: системный загрузчик колонки 32-битный и старый
L=/data/local/opt/soloist/lib
exec "$L/ld-linux-aarch64.so.1" --library-path "$L" /data/local/opt/soloist/bin/soloist.bin "$@"
EOF
chmod +x "$OUT/bin/soloist"

"$OUT/bin/soloist.bin" --version
du -sh "$OUT"
echo "=== готово: $OUT ==="
