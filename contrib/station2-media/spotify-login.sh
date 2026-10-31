#!/usr/bin/env bash
# Вход Spotify на Станции 2 через OAuth — нужен один раз и после сброса колонки.
# librespot принимает ответ OAuth на 127.0.0.1:5588 колонки; этот порт пробрасывается
# на Mac по SSH, а страница входа открывается в браузере по умолчанию. После входа
# librespot сохраняет его в spotify-cache, и обычная служба дальше входит сама.
#
#   ./spotify-login.sh <IP колонки>
set -euo pipefail

IP=${1:?"использование: $0 <IP колонки>"}
HERE=$(cd "$(dirname "$0")" && pwd)
KEY=$HOME/.ssh/yandex_station2
PORT=5588
LOG=$(mktemp)
SSH_PID=
# || true: туннель обычно уже закрылся сам, а упавший kill под set -e дал бы код 1
trap 'rm -f "$LOG"; [ -n "$SSH_PID" ] && kill "$SSH_PID" 2>/dev/null || true' EXIT

ssh_() {
  ssh -i "$KEY" -p 2222 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
      -o UserKnownHostsFile="$HERE/known_hosts" "$@"
}

# Временный librespot с OAuth вместо службы, с тем же кэшем. audio-owner.sh тут же
# поднимает службу заново, поэтому без объявления в сети: иначе avahi отвечает
# «Local name collision», и эта строка ERROR обрывает ожидание входа ниже.
ssh_ -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:$PORT" "root@$IP" '. /data/local/opt/ap2/common.sh
  for p in $(pids_matching "$B/librespot"); do kill "$p"; done; sleep 1
  exec "$B/librespot" --enable-oauth --oauth-port '"$PORT"' --name "Станция 2" \
    --device-type speaker --backend subprocess --device "$AP/spotify-sink.sh" --format S16 \
    --cache "$AP/spotify-cache" --disable-audio-cache --disable-discovery 2>&1' > "$LOG" 2>&1 &
SSH_PID=$!

for _ in $(seq 1 30); do grep -q 'accounts.spotify.com' "$LOG" && break; sleep 1; done
# || true: без ссылки (например, вход уже есть в кэше) set -e молча оборвал бы скрипт
URL=$(grep -o 'https://accounts.spotify.com/authorize[^ ]*' "$LOG" | head -1 || true)
[ -n "$URL" ] || { cat "$LOG"; echo "ОШИБКА: librespot не выдал ссылку входа" >&2; exit 1; }
if command -v open >/dev/null && [ "$(uname)" = Darwin ]; then
  open "$URL"
elif command -v xdg-open >/dev/null; then
  xdg-open "$URL" >/dev/null 2>&1 || true
fi
echo "Если браузер не открылся, откройте ссылку вручную:"
echo "$URL"
echo "Войдите в Spotify в браузере и нажмите «Принимаю»…"

for _ in $(seq 1 300); do
  grep -q 'Authenticated as' "$LOG" && break
  grep -qE 'ERROR|Failed' "$LOG" && { cat "$LOG"; exit 1; }
  sleep 1
done
grep -q 'Authenticated as' "$LOG" || { echo "ОШИБКА: вход не завершился за 5 минут" >&2; exit 1; }
echo "Вход выполнен, возвращаю обычную службу"

# Служба, поднятая audio-owner.sh во время входа, стартовала без ключей — её тоже
ssh_ "root@$IP" '. /data/local/opt/ap2/common.sh
  for p in $(pids_matching "$B/librespot"); do kill "$p"; done; sleep 2
  $AP/ap2.sh spotify; sleep 5; tail -3 $LOGD/spotify.log'
