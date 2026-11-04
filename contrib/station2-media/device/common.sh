# Общие функции для ap2.sh и audio-owner.sh (подключается через «.»).
AP=/data/local/opt/ap2
B=$AP/bin
E=$AP/etc
LOGD=/data/local/tmp/ap2
MEDIAD_BIN=/system/vendor/quasar/maind
MEDIAD_MATCH="$MEDIAD_BIN --mediad"
# Имя колонки в Spotify Connect (librespot) и в поиске устройства через Web API
SPOTIFY_NAME="Станция 2"
# Кривая громкости librespot в дБ: на полной шкале регулятора
# (36 дБ) половина ползунка звучит слишком тихо, ~25 дБ на слух совпадает с привычным
# шагом AirPlay (24 и меньше librespot считает «узким аппаратным» регулятором и
# переходит на линейную шкалу)
SPOTIFY_VOLUME_RANGE=25
# Spotify Soloist (soloist.sh) — вместо librespot, когда тот выключен
SOLOIST=/data/local/opt/soloist
soloist_ready() { [ ! -x "$B/librespot" ] && [ -s "$SOLOIST/etc/api-key" ]; }

# Разговор с ChatGPT (Alisa Voice). Его клиент выводит звук через общий dmix, а наши
# плееры занимают hw:0,0 монопольно (они 64-битные, dmix с 32-битной Алисой не делят):
# если звук занят, клиент падает целиком и монитор возвращает обычную Алису. Поэтому на
# время чата — метка: наши плееры звук не берут и mediad Алисы не трогают.
CHAT_FLAG=/tmp/ap2-chat
# Вывод Spotify (spotify-sink.sh): наш aplay с -D spotify или системный с -D spotify_shared
SPOTIFY_OUT="aplay -q -D spotify"
# Вывод AirPlay: shairport пишет в канал, системный aplay несёт его в общий dmix
AIRPLAY_FIFO=/run/ap2-airplay.fifo
AIRPLAY_OUT="aplay -q -D airplay_shared"
airplay_shared() { grep -q '^ *output_backend = "pipe"' "$E/shairport-sync.conf" 2>/dev/null; }

# Громкость с телефона (Spotify, AirPlay) -> Master. Ползунок — доля амплитуды, как у
# большинства колонок: 13% ≈ −18 дБ, 50% = −6 дБ. Master 0..255 — это −36..0 дБ
# (asound.conf), шаг 36/255 дБ = множитель амплитуды 1,016387; awk на колонке без
# математики, поэтому степень — циклом. Ползунок — 0..65536.
# Шкала колонки: у Станции 2 голос Алисы мимо Master — 36 дБ, у Мини 2 Алиса играет через
# системный softvol на Master (−51 дБ) — install.sh ставит ту же шкалу, шаг 51/255 дБ = 1,023293
MASTER_STEP_PPM=1016387
# Кривая ползунка: amplitude — доля амплитуды (выше); alice — как у самой Алисы, процент
# ползунка = процент Master (set_volume.sh). На Мини 2 Алиса звучит через Master, и
# доля амплитуды давала на первом шаге iPhone −24 дБ — как Алиса на 5. install.sh ставит alice.
VOLUME_CURVE=amplitude
master_get() {
  ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -D default get Master |
    sed -n 's/.*Playback \([0-9]*\) \[.*/\1/p' | head -1
}
master_set() { ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -q -D default set Master "$1"; }
stream_of() { # Master -> ползунок 0..65536
  [ "$VOLUME_CURVE" = alice ] && { echo $(($1 * 65536 / 255)); return; }
  x=$((65536 << 16)) i=$1
  while [ "$i" -lt 255 ]; do x=$((x * 1000000 / MASTER_STEP_PPM)) i=$((i + 1)); done
  echo $((x >> 16))
}
master_of() { # ползунок -> ближайший сверху Master
  [ "$VOLUME_CURVE" = alice ] && { echo $((($1 * 255 + 65535) / 65536)); return; }
  t=$(($1 << 16)) x=$((65536 << 16)) m=255
  while [ "$m" -gt 0 ] && [ $((x * 1000000 / MASTER_STEP_PPM)) -ge "$t" ]; do
    x=$((x * 1000000 / MASTER_STEP_PPM)) m=$((m - 1))
  done
  echo "$m"
}

# Регулятор AP2 Duck: приглушение нашей музыки (asound.conf) — пока Алиса слушает и пока идёт чат
duck_set() { ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -q -D default set "AP2 Duck" "$1" 2>/dev/null; }
ALISA_BIN=/data/opt/alisa-standalone/bin/alisa-standalone
chat_active() { [ -f "$CHAT_FLAG" ]; }
# Монитор Alisa Voice запущен: mediad Алисы связан с её клиентом, убивать его нельзя —
# клиент падает на следующем чате. Ждём, пока mediad сам отпустит звук (в простое он его не держит).
alisa_running() { [ -n "$(pids_matching "/data/opt/alisa-standalone/run.sh monitor")" ]; }
alisa_phase() { # starting|opening|active — идёт разговор; idle — нет; пусто — клиент не запущен
  "$ALISA_BIN" status 2>/dev/null | sed -n 's/^  "phase": *"\([a-z_]*\)".*/\1/p'
}
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/ap2_bus
# из SSH-сессии dropbear приходит PATH=/usr/bin:/bin, а start-stop-daemon лежит в /sbin
export PATH=/sbin:/usr/sbin:/bin:/usr/bin

mkdir -p "$LOGD"

# Поиск процессов по подстроке командной строки. Один ps на весь список (перебор
# /proc с tr на каждый процесс стоил ~0,5 с и сотни запусков программ за проход).
# Шаблон идёт через окружение, а не аргументом: иначе awk находил бы сам себя, а
# ps|grep — того, кто его запустил; свою оболочку и родителя исключаем явно.
pids_matching() {
  ps -o pid,args 2>/dev/null | PAT=$1 ME=$$ PARENT=$PPID awk '
    NR > 1 {
      line = $0; sub(/^ *[0-9]+ /, "", line)
      if (index(line, ENVIRON["PAT"]) && $1 != ENVIRON["ME"] && $1 != ENVIRON["PARENT"]) print $1
    }'
}

holds_pcm() { # pid — держит ли процесс устройство воспроизведения
  [ -n "$1" ] || return 1
  for f in /proc/$1/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}

pcm_busy() {
  for f in /proc/[0-9]*/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}

# Префикс запуска для звуковых процессов: реальное время, если ядро разрешает, иначе
# nice. Без него вывод звука делит процессор с демонами Яндекса и иногда заикается.
audio_prio() {
  if chrt -r 30 true 2>/dev/null; then echo "chrt -r 30"; else echo "nice -n -10"; fi
}

# Лог длиннее 1 МБ начинаем заново: /data маленький
trim_log() {
  [ -f "$1" ] && [ "$(wc -c < "$1")" -gt 1048576 ] && : > "$1"
  return 0
}

# Медиа-демон колонки (голос Алисы и её плеер). Лаунчер quasar поднимает его после
# падения не сразу (до 600 с), поэтому поднимаем сами и следим, чтобы он был один:
# два экземпляра дерутся за звук, и Алиса молчит.
start_mediad() {
  [ -x "$MEDIAD_BIN" ] || return 0
  PIDS=$(pids_matching "$MEDIAD_MATCH")
  N=$(printf '%s\n' "$PIDS" | grep -c .)
  if [ "$N" -gt 1 ]; then
    # Экземпляр лаунчера оставляем, убираем только свои: если убить и его, лаунчер
    # поднимает новый через 600 с, и дубль с убийством повторяются каждые 10 минут
    L=$(pids_matching "quasar_launcher2" | head -1)
    K=0
    for p in $PIDS; do
      [ -n "$L" ] && [ "$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)" = "$L" ] && continue
      kill -9 "$p" 2>/dev/null
      K=$((K + 1))
    done
    sleep 2
    echo "$(date): убрал дубли mediad (было $N, убрано $K)" >> "$LOGD/owner.log"
    N=$((N - K))
  fi
  if [ "$N" -eq 0 ]; then
    cd /data/quasar 2>/dev/null || cd /
    envs=$(mediad_env)
    [ -n "$envs" ] || envs="MALLOC_ARENA_MAX=2
CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt"
    ( IFS='
'
      # shellcheck disable=SC2086
      exec env $envs nohup "$MEDIAD_BIN" --mediad ) >> /data/quasar/mediad.log 2>&1 < /dev/null &
    echo "$(date): mediad поднят" >> "$LOGD/owner.log"
  fi
}

# Окружение mediad — из файла, с которым сейчас запущен лаунчер quasar: Alisa Voice запускает
# его со своим launch.bridge.json, где mediad получает LD_PRELOAD с фильтром речи Алисы.
# LD_LIBRARY_PATH лаунчера тоже передаём: без него preload не найдёт библиотеки.
mediad_env() {
  lp=$(pids_matching "quasar_launcher2" | head -1)
  [ -n "$lp" ] || return 0
  f=$(tr '\0' '\n' < "/proc/$lp/cmdline" | sed -n 2p)
  tr '\0' '\n' < "/proc/$lp/environ" 2>/dev/null | grep '^LD_LIBRARY_PATH='
  [ -f "$f" ] && "$B/jq" -r '.nodes[]?.tasks[]? | select((.arg // []) | index("--mediad")) | .envs[]?' "$f" 2>/dev/null
}
