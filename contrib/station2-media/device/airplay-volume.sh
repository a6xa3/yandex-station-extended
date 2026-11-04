#!/bin/sh
# shairport-sync (run_this_when_volume_is_set): громкость с iPhone/Mac -> регулятор Master,
# тот же, что двигают Алиса и сенсорная панель. В режиме вывода в канал (pipe) shairport сам
# громкость не применяет (ignore_volume_control), а ALSA-регулятора у него нет.
# Аргумент — громкость AirPlay: -30..0 линейно по положению ползунка, -144 — без звука.
# Положение ползунка пересчитываем как у Spotify (master_of в common.sh): линейно по дБ
# нижняя половина ползунка была почти тишиной.
. /data/local/opt/ap2/common.sh
case "$1" in
  -144*) raw=0 ;;
  *) pos=$(awk -v v="$1" 'BEGIN { p = int((v + 30) / 30 * 65536 + 0.5)
                                  if (p < 0) p = 0; if (p > 65536) p = 65536; print p }')
     raw=$(master_of "$pos")
     [ "$raw" -lt 1 ] && raw=1 ;;   # 0 — тишина, а ползунок не на нуле
esac
[ -n "$raw" ] && master_set "$raw"
