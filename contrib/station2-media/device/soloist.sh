#!/bin/sh
# Spotify Soloist на Станции 2 (замена librespot, которому Spotify не выдаёт ключи треков
# новых аккаунтов). Soloist играет в виртуальный выход PulseAudio; пока он играет,
# звук уходит в ALSA тем же путём, что у librespot (spotify-sink.sh), поэтому
# audio-owner.sh, приглушение для голоса и общая громкость работают без изменений.
#   soloist.sh start | stop | status
#   soloist.sh run-pulse | run-soloist | run-watch — в переднем плане
# Ключ Soloist API — в etc/api-key (одна строка, из developer.spotify.com/dashboard/soloist).
. /data/local/opt/ap2/common.sh
S=/data/local/opt/soloist
R=/run/soloist
export PULSE_SERVER=unix:$R/native
PAREC="$S/bin/parec"
GRACE=3   # столько секунд тишины, прежде чем вернуть звук Алисе (паузы между треками)

pa() { "$S/bin/pactl" "$@" 2>/dev/null; }

spawn() { # pidfile аргументы /bin/sh...
  pf=$1; shift
  rm -f "$pf"
  start-stop-daemon -S -b -m -p "$pf" -x /bin/sh -- "$@"
}

run_pulse() {
  mkdir -p "$R"
  cd "$R" || exit 1
  trim_log "$LOGD/pulse.log"
  # flat-volumes: громкость потока Soloist уходит в «аппаратный» регулятор выхода
  # (пропатченный module-null-sink), то есть звук PulseAudio не трогает
  echo "flat-volumes = yes" > "$R/daemon.conf"
  PULSE_CONFIG=$R/daemon.conf HOME=$R XDG_RUNTIME_DIR=$R XDG_CONFIG_HOME=$R \
    exec "$S/bin/pulseaudio" -n -F "$S/etc/soloist.pa" \
    --daemonize=no --exit-idle-time=-1 --use-pid-file=no --disable-shm=yes \
    --dl-search-path="$S/lib/pulse" --log-target=stderr --log-level=error >>"$LOGD/pulse.log" 2>&1
}

# Кэш минимум 100 МБ (меньше Soloist не принимает) — на /data, в ОЗУ ему тесно
run_soloist() {
  trim_log "$LOGD/soloist.log"
  SSL_CERT_FILE=$S/lib/ca-certificates.crt exec "$S/bin/soloist" -n "$SPOTIFY_NAME" \
    -k "$(cat "$S/etc/api-key")" -D "$S/data" -C "$S/cache" -z 100 -w 127.0.0.1:0 \
    >>"$LOGD/soloist.log" 2>&1
}

piping() { [ -n "$(pids_matching "$PAREC")" ]; }

# Громкость общая с Алисой. Soloist ставит громкость своему потоку в PulseAudio и
# сам подхватывает её изменения, поэтому поток — это ползунок Spotify. Звук PulseAudio
# не приглушает (run_pulse), его громкость — только Master колонки.
# Проценты Spotify — доля амплитуды, как у большинства колонок: 13% ≈ −18 дБ (Алиса на 5),
# 50% = −6 дБ. Master 0..255 — это −36..0 дБ (asound.conf), шаг 36/255 дБ = множитель
# амплитуды 1,016387; awk на колонке без математики, поэтому степень — циклом.
master_get() {
  ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -D default get Master |
    sed -n 's/.*Playback \([0-9]*\) \[.*/\1/p' | head -1
}
master_set() { ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -q -D default set Master "$1"; }
stream_of() { # Master -> поток 0..65536
  x=$((65536 << 16)) i=$1
  while [ "$i" -lt 255 ]; do x=$((x * 1000000 / 1016387)) i=$((i + 1)); done
  echo $((x >> 16))
}
master_of() { # поток -> ближайший сверху Master
  t=$(($1 << 16)) x=$((65536 << 16)) m=255
  while [ "$m" -gt 0 ] && [ $((x * 1000000 / 1016387)) -ge "$t" ]; do
    x=$((x * 1000000 / 1016387)) m=$((m - 1))
  done
  echo "$m"
}
# Ползунок Spotify сдвинулся — двигаем Master; сдвинулся Master (панель, голос) или
# поток новый — двигаем ползунок. Сдвиги меньше 1,5% — округление при обмене со
# Spotify, а не ползунок.
sync_volume() { # индекс громкость_потока
  d=$(( $2 - ${last_v:-0} ))
  if [ "$1" = "$last_idx" ] && [ "${d#-}" -gt 1000 ]; then
    last_v=$2
    m=$(master_of "$2")
    master_set "$m"
  else
    m=$(master_get)
    [ -n "$m" ] || return 0
    if [ "$1" != "$last_idx" ] || [ "$m" != "$last_m" ]; then
      last_v=$(stream_of "$m")
      pa set-sink-input-volume "$1" "$last_v"
    fi
  fi
  last_idx=$1 last_m=$m
}

stop_pipe() {
  for p in $(pids_matching "$PAREC") $(pids_matching "/bin/sh $AP/spotify-sink.sh") \
           $(pids_matching "$B/aplay -q -D spotify"); do
    kill "$p" 2>/dev/null
  done
}

# События потоков PulseAudio -> fd 3. Только sink-input: каждый вызов pactl сам
# порождает события клиента. FIFO открыт на чтение и запись, чтобы не зависнуть на
# открытии, если PulseAudio лежит; подписку поднимаем заново, когда она умерла.
events() {
  [ -n "$sub" ] && kill -0 "$sub" 2>/dev/null && return
  rm -f "$R/events"
  mkfifo "$R/events"
  exec 3<>"$R/events"
  "$S/bin/pactl" subscribe 2>/dev/null | awk '/sink-input/ { print; fflush() }' >&3 &
  sub=$!
}

# На событие потока отвечаем сразу, чтобы Master шёл за ползунком без секундной задержки
run_watch() {
  quiet_since= last_idx= last_v= last_m= sub=
  while :; do
    events
    read -t 1 -r _ <&3
    info=$(pa list sink-inputs)
    idx=$(printf '%s\n' "$info" | sed -n 's/^Sink Input #//p' | head -1)
    v=$(printf '%s\n' "$info" | sed -n 's/.*Volume: front-left: \([0-9]*\) .*/\1/p' | head -1)
    [ -n "$idx" ] && [ -n "$v" ] && sync_volume "$idx" "$v"
    if printf '%s\n' "$info" | grep -q 'Corked: no'; then
      quiet_since=
      piping || { "$PAREC" -d soloist.monitor --raw --format=s16le --rate=44100 --channels=2 \
                    --latency-msec=100 | /bin/sh "$AP/spotify-sink.sh"; } &
    elif piping; then
      now=$(date +%s)
      [ -n "$quiet_since" ] || quiet_since=$now
      [ $((now - quiet_since)) -ge "$GRACE" ] && { stop_pipe; quiet_since=; }
    fi
  done
}

start_all() {
  [ -s "$S/etc/api-key" ] || { echo "нет $S/etc/api-key" >&2; return 1; }
  if [ -z "$(pids_matching "$S/bin/pulseaudio")" ]; then
    spawn /run/soloist-pulse.pid "$S/soloist.sh" run-pulse
    sleep 2
  fi
  [ -n "$(pids_matching "$S/bin/soloist.bin")" ] || spawn /run/soloist.pid "$S/soloist.sh" run-soloist
  [ -n "$(pids_matching "$S/soloist.sh run-watch")" ] || spawn /run/soloist-watch.pid "$S/soloist.sh" run-watch
}

stop_all() {
  for m in "$S/soloist.sh run-watch" "$S/bin/pactl subscribe" "$S/bin/soloist.bin" "$S/bin/pulseaudio"; do
    for p in $(pids_matching "$m"); do kill "$p" 2>/dev/null; done
  done
  stop_pipe
}

case "$1" in
  start)       start_all ;;
  stop)        stop_all ;;
  status)
    for m in "$S/bin/pulseaudio" "$S/bin/soloist.bin" "$S/soloist.sh run-watch" "$PAREC"; do
      printf '%-30s %s\n' "${m##*/}" "$(pids_matching "$m" | tr '\n' ' ')"
    done
    pa list short sink-inputs
    tail -5 "$LOGD/soloist.log" 2>/dev/null ;;
  run-pulse)   run_pulse ;;
  run-soloist) run_soloist ;;
  run-watch)   run_watch ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 1 ;;
esac
