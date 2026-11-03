#!/bin/sh
# Голосовое управление Spotify на этой колонке. Музыку голосом включает Алиса (Яндекс
# Музыка); в Spotify — только если назвать его: «Алиса, включи Маркула в Спотифай».
# «Стоп», «дальше», «назад», «продолжи» управляют Spotify, пока он играет, а если Алиса
# включает свою музыку — Spotify встаёт на паузу и уступает ей звук.
# Текст фразы берём у alice-text (локальный канал Алисы), а как Алиса фразу поняла — из
# лога maind. В лог попадают только команды Spotify, остальная речь никуда не пишется.
. /data/local/opt/ap2/common.sh
LOG=$LOGD/voice.log
API_SH=$AP/spotify-api.sh
ACTIVE=/tmp/spotify-voice.active   # время последнего запуска Spotify голосом
RECENT_SECONDS=3600
DUCK=/tmp/ap2-duck                 # метка текущего приглушения
DUCK_LEVEL=25%                     # AP2 Duck: 25% шкалы ~ -22 дБ
DUCK_MAX_SECONDS=15                # страховка, если «свободна» не придёт

note() { echo "$(date): $*" >> "$LOG"; }

duck_set() { ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -q -D default set "AP2 Duck" "$1" 2>/dev/null; }

# Пока Алиса слушает, музыка AirPlay и Spotify тише — иначе команда тонет в ней
duck_on() {
  mark=$(date +%s)
  echo "$mark" > "$DUCK"
  duck_set "$DUCK_LEVEL"
  ( sleep "$DUCK_MAX_SECONDS"; [ "$(cat "$DUCK" 2>/dev/null)" = "$mark" ] && duck_off ) &
}

duck_off() {
  rm -f "$DUCK"
  duck_set 100%
}

# Как Алиса поняла фразу — по директивам, которые она выполнила (routeDirective в логе
# maind), а не по словам: «Стоп», «хватит», «пауза» — для неё всё это player_pause.
# Смотрим только routeDirective: в строке с ответом перечислено и то, что уже стоит в
# очереди, — во время её музыки там всегда есть audio_play.
MAIND_LOG=/data/quasar/daemons_logs/maind.log
ROUTED='routeDirective \(xx[0-9a-f]+\)'
ALICE_MUSIC="${ROUTED}(music_play|audio_play|radio_play|multiroom_play|audio_player_play_directive)\b"
# Своя музыка Алисы закрыта: на «стоп», если играла она, player_pause не приходит
ALICE_MUSIC_STOPPED='Music session changed to player_finish'
PLAYER_DIRECTIVES="${ROUTED}(player_pause|player_continue|player_next_track|playback_next|player_previous_track|playback_prev)\b|$ALICE_MUSIC_STOPPED|$ALICE_MUSIC"

log_size() { wc -c < "$MAIND_LOG" 2>/dev/null || echo 0; }

# shortcut: если лог сменился сразу после ответа, ответ остался в maind.log.1 и фраза
# пропускается — Алиса отработает её сама
new_log() { # смещение — нужные строки лога, появившиеся после него
  off=$1
  [ "$(log_size)" -lt "$off" ] && off=0
  tail -c +$((off + 1)) "$MAIND_LOG" 2>/dev/null |
    grep -E 'routeDirective|onAliceStateChanged: IDLE|Music session changed'
}

# смещение шаблон — печатает строки ответа Алисы на фразу. Ждём, пока она не закончит с
# фразой (IDLE), до 10 с, но выходим сразу, как нашлась директива из шаблона: после
# «стоп» музыка играет, пока мы ждём
alice_reply() {
  i=0
  while [ "$i" -lt 50 ]; do
    usleep 200000
    i=$((i + 1))
    new=$(new_log "$1")
    printf '%s\n' "$new" | grep -q -E "$2" && break
    printf '%s\n' "$new" | grep -q 'onAliceStateChanged: IDLE' && break
  done
  printf '%s\n' "$new"
}

# Soloist принимает команды локально за ~0,1 с, Web API через облако — около секунды
soloist_ctl() { soloist_ready && "$SOLOIST/bin/soloist" ctl -D "$SOLOIST/data" "$1" >/dev/null 2>&1; }

spotify_playing_now() { [ -n "$(pids_matching "$B/aplay -q -D spotify")" ]; }

# Spotify играет или включался голосом недавно — тогда «пауза», «дальше» для него
spotify_recent() {
  spotify_playing_now && return 0
  [ -f "$ACTIVE" ] && [ $(( $(date +%s) - $(cat "$ACTIVE") )) -lt "$RECENT_SECONDS" ]
}

player_command() { # смещение
  reply=$(alice_reply "$1" "$PLAYER_DIRECTIVES")
  has() { printf '%s\n' "$reply" | grep -q -E "$1"; }
  # команда spotify-api.sh и команда soloist ctl
  if has "${ROUTED}player_pause\b|$ALICE_MUSIC_STOPPED"; then api=pause ctl=pause
  elif has "$ALICE_MUSIC"; then
    spotify_playing_now || return 0   # Алиса включает своё — Spotify уступает
    api=pause ctl=pause
  elif has "${ROUTED}player_continue\b"; then api=resume ctl=play
  elif has "${ROUTED}(player_next_track|playback_next)\b"; then api=next ctl=next
  elif has "${ROUTED}(player_previous_track|playback_prev)\b"; then api=prev ctl=prev
  else return 0
  fi
  note "$api"
  soloist_ctl "$ctl" || "$API_SH" "$api" >> "$LOG" 2>&1 || note "не вышло: $api"
}

play_spotify() { # «маркула», «песню X», «альбом X», «плейлист X», «музыку» — без слова Spotify
  q=$(echo "$1" | sed -E 's/ ?(в|на|из)? (спотифай|спотифае|спотифая|Спотифай|Спотифае|Спотифая|spotify|Spotify)//; s/ пожалуйста$//; s/^ //')
  mode=auto
  case "$q" in
    песню\ *|трек\ *|композицию\ *) mode=track; q=${q#* } ;;
    альбом\ *) mode=album; q=${q#* } ;;
    плейлист\ *|подборку\ *) mode=playlist; q=${q#* } ;;
  esac
  case "$q" in
    ''|музыку|музыка|что-нибудь|мою\ музыку|любимое|любимую\ музыку|любимые\ песни) set -- liked ;;
    *) set -- play "$mode" "$q" ;;
  esac
  note "$*"
  if "$API_SH" "$@" >> "$LOG" 2>&1; then
    date +%s > "$ACTIVE"
  else
    note "не вышло: $*"
  fi
}

handle() {
  t=$1
  # Состояние Алисы от alice-text: 1 — слушает, 3 — фраза распознана, 0 — свободна
  case "$t" in
    "@state 1") duck_on; return 0 ;;
    "@state 0") [ -f "$DUCK" ] && duck_off; return 0 ;;
    @state\ *) return 0 ;;
  esac
  # «… в ютубе» — команда для ytmd.py (YouTube Music), не для Spotify
  case "$t" in *ютуб*|*Ютуб*|*youtube*|*YouTube*) return 0 ;; esac
  case "$t" in
    *потиф*|*potify*)
      case "$t" in
        *оставь\ *|*ключи\ *|*грай\ *)
          q=$(echo "$t" | sed -E 's/^.*(Поставь|поставь|Включи|включи|Играй|играй) //')
          [ "$q" != "$t" ] && { play_spotify "$q" & return 0; }
          ;;
      esac
      ;;
  esac
  # остальное — Алисе; Spotify подстраивается под то, что она сделала
  spotify_recent && player_command "$(log_size)" &
}

trim_log "$LOG"
duck_off
note "слушатель запущен"
"$B/alice-text" | while IFS= read -r line; do
  handle "$line"
done
