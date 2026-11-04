#!/bin/sh
# Вывод Spotify: звук приходит на stdin (S16LE, 44,1 кГц, стерео) — от librespot
# (--backend subprocess) или от наблюдателя Soloist (soloist.sh run-watch).
# Если у колонки есть системный dmix, играем в него системным aplay вместе с Алисой и
# ChatGPT (etc/asound-shared.conf) — никого не выгоняя. Иначе — монопольно на hw:0,0, как
# AirPlay: устройство держит медиа-демон колонки, его освобождаем.
. /data/local/opt/ap2/common.sh
# идёт чат с ChatGPT — звук его (common.sh, CHAT_FLAG)
chat_active && exit 0
# shellcheck disable=SC2046
if [ -x /usr/bin/aplay ] && [ -f "$E/asound-shared.conf" ] && grep -q 'dmix_spk_plug' /etc/asound.conf 2>/dev/null; then
  export ALSA_CONFIG_PATH=$E/asound-shared.conf
  exec $(audio_prio) /usr/bin/aplay -q -D spotify_shared -f S16_LE -c 2 -r 44100 -t raw --buffer-time=500000
fi
i=0
if alisa_running; then
  # с Alisa Voice mediad не убиваем (common.sh), ждём до 15 с
  while pcm_busy && [ "$i" -lt 75 ]; do sleep 0.2; i=$((i+1)); done
  [ "$i" -gt 0 ] && echo "$(date): Spotify ждал звук от Алисы $((i / 5)) с" >> "$LOGD/owner.log"
else
  while pcm_busy && [ "$i" -lt 30 ]; do
    for p in $(pids_matching "$MEDIAD_MATCH"); do kill -9 "$p" 2>/dev/null; done
    sleep 0.2
    i=$((i+1))
  done
fi
export ALSA_CONFIG_PATH=$E/asound.conf
# буфер 0,5 с переживает короткие провалы сети и процессора
exec $(audio_prio) "$B/aplay" -q -D spotify -f S16_LE -c 2 -r 44100 -t raw --buffer-time=500000
