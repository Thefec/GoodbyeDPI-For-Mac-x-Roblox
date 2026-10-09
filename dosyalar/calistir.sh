#!/bin/bash
# GoodbyeDPI-Mac arka plan servisi. launchd tarafından root olarak, Mac açılışında çalıştırılır.
# Argüman 1: kullanıcının ayarlar.conf dosyasının yolu.
#
# Ne yapar: 8 alternatifi (profil-1..8.toml) sırayla başlatır, her birinde Roblox'a bağlanmayı dener,
# bağlantıyı açan ilk alternatifi bulunca sistem proxy'sini ona yönlendirir ve izler.
# Bağlantı sonradan koparsa kendiliğinden yeniden tarar.
# macOS'un bash'i 3.2 sürümü: bu betik ona uyumlu yazıldı.

USER_CONF="$1"
CONF_DIR="${GDPI_CONF_DIR:-/usr/local/etc/goodbyedpi}"
BIN="${GDPI_BIN:-/usr/local/libexec/goodbyedpi/spoofdpi}"
STATE_FILE="$CONF_DIR/son-profil"

PORT=8080
TOTAL=8
CHECK_EVERY="${GDPI_CHECK_EVERY:-30}"       # sağlıklı çalışırken kontrol aralığı (sn)
RETRY_WAIT="${GDPI_RETRY_WAIT:-30}"         # internet yokken bekleme (sn)
DEGRADED_WAIT="${GDPI_DEGRADED_WAIT:-300}"  # hiçbiri doğrulanamazsa yeniden taramadan önce bekleme (sn)
STARTUP_WAIT="${GDPI_STARTUP_WAIT:-3}"      # tun modunda başlangıç beklemesi (sn)

# Bağlantının "çalışıyor" sayılması için hepsine erişilebilmeli
TEST_URLS=("https://www.roblox.com" "https://apis.roblox.com")
# Proxy'siz, doğrudan internet var mı kontrolü
CONTROL_URL="http://captive.apple.com/hotspot-detect.html"

# --- Ayarlar (kullanıcı dosyası root olarak okunuyor: ÇALIŞTIRMA yok, yalnızca izinli değerler) ---
PINNED="0"      # 0 = otomatik, 1-8 = sabit alternatif
MOD="http"
if [ -r "$USER_CONF" ]; then
  v="$(grep -E '^PROFIL=(otomatik|[1-8])[[:space:]]*$' "$USER_CONF" | tail -n 1 | cut -d= -f2 | tr -d '[:space:]')"
  if [ -n "$v" ] && [ "$v" != "otomatik" ]; then PINNED="$v"; fi
  v="$(grep -E '^MOD=(http|tun)[[:space:]]*$' "$USER_CONF" | tail -n 1 | cut -d= -f2 | tr -d '[:space:]')"
  if [ -n "$v" ]; then MOD="$v"; fi
fi

SPID=""
AVOID=""   # bağlantısı kopan alternatif: yeniden taramada en sona alınır

log() { echo "$(date '+%F %T') $*"; }

# Sinyalle kesilebilen bekleme
nap() { sleep "$1" & wait "$!" 2>/dev/null; }

# --- Sistem proxy'si ---
list_services() { networksetup -listallnetworkservices 2>/dev/null | tail -n +2; }

set_proxy() {
  list_services | while IFS= read -r svc; do
    case "$svc" in \**) continue ;; esac   # başında * olanlar devre dışı servisler
    cur="$(networksetup -getwebproxy "$svc" 2>/dev/null)"
    en="$(echo "$cur" | awk -F': ' '/^Enabled/{print $2}')"
    srv="$(echo "$cur" | awk -F': ' '/^Server/{print $2}')"
    # Kullanıcının kendi proxy'si açıksa dokunma
    if [ "$en" = "Yes" ] && [ "$srv" != "127.0.0.1" ]; then continue; fi
    networksetup -setwebproxy "$svc" 127.0.0.1 "$PORT" >/dev/null 2>&1
    networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$PORT" >/dev/null 2>&1
  done
}

# Yalnızca 127.0.0.1'e işaret eden proxy'leri kapatır
reset_proxy() {
  list_services | sed 's/^\*//' | while IFS= read -r svc; do
    for kind in webproxy securewebproxy; do
      server="$(networksetup -get${kind} "$svc" 2>/dev/null | awk -F': ' '/^Server/{print $2}')"
      if [ "$server" = "127.0.0.1" ]; then
        networksetup -set${kind}state "$svc" off >/dev/null 2>&1
      fi
    done
  done
}

clear_proxy() { if [ "$MOD" = "http" ]; then reset_proxy; fi; }

# --- spoofdpi yönetimi ---
start_spoofdpi() {
  local args=(--config "$CONF_DIR/profil-$1.toml" --no-tui --log-level warn)
  if [ "$MOD" = "tun" ]; then args+=(--app-mode tun); fi
  "$BIN" "${args[@]}" &
  SPID=$!
}

stop_spoofdpi() {
  if [ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null; then
    kill -TERM "$SPID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SPID" 2>/dev/null || break
      sleep 0.3
    done
    kill -KILL "$SPID" 2>/dev/null
  fi
  if [ -n "$SPID" ]; then wait "$SPID" 2>/dev/null; fi
  SPID=""
}

wait_ready() {
  if [ "$MOD" = "tun" ]; then nap "$STARTUP_WAIT"; kill -0 "$SPID" 2>/dev/null; return; fi
  for _ in $(seq 1 20); do
    kill -0 "$SPID" 2>/dev/null || return 1
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && return 0
    nap 0.5
  done
  return 1
}

# --- Bağlantı sınamaları ---
http_code() {
  if [ "$MOD" = "http" ]; then
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 -x "http://127.0.0.1:$PORT" "$1" 2>/dev/null
  else
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$1" 2>/dev/null
  fi
}

# Roblox adreslerine ulaşılabiliyor mu (2xx-4xx yanıt = ulaşıldı)
roblox_ok() {
  local url code
  for url in "${TEST_URLS[@]}"; do
    code="$(http_code "$url")"
    case "$code" in
      [234][0-9][0-9]) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Proxy'siz doğrudan internet var mı
internet_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 6 "$CONTROL_URL" 2>/dev/null)"
  case "$code" in
    [23][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Deneme sırası: önce son çalışan, sonra 1..8 ---
build_order() {
  ORDER=()
  if [ "$PINNED" != "0" ]; then ORDER=("$PINNED"); return; fi
  local first="" i
  if [ -r "$STATE_FILE" ]; then first="$(grep -E '^[1-8]$' "$STATE_FILE" | head -n 1)"; fi
  # Az önce kopan alternatif en sona atılır (hemen aynısını tekrar deneme)
  if [ -n "$AVOID" ] && [ "$first" = "$AVOID" ]; then first=""; fi
  if [ -n "$first" ]; then ORDER+=("$first"); fi
  for i in $(seq 1 "$TOTAL"); do
    if [ "$i" != "$first" ] && [ "$i" != "$AVOID" ]; then ORDER+=("$i"); fi
  done
  if [ -n "$AVOID" ]; then ORDER+=("$AVOID"); fi
}

on_term() {
  log "kapatılıyor"
  stop_spoofdpi
  clear_proxy
  exit 0
}
trap on_term TERM INT

log "başladı: alternatif=$( [ "$PINNED" = "0" ] && echo otomatik || echo "$PINNED" ) mod=$MOD"
clear_proxy   # önceki çalışmadan kalmış proxy ayarı varsa temizle

OFFLINE_LOGGED=0
while true; do
  # Doğrudan internet yoksa alternatifleri boşuna döndürme
  if [ "$PINNED" = "0" ] && ! internet_ok; then
    if [ "$OFFLINE_LOGGED" = "0" ]; then log "internet yok, bekleniyor"; OFFLINE_LOGGED=1; fi
    nap "$RETRY_WAIT"
    continue
  fi
  OFFLINE_LOGGED=0

  build_order
  FOUND=""
  for p in "${ORDER[@]}"; do
    log "alternatif $p deneniyor"
    start_spoofdpi "$p"
    if wait_ready; then
      if [ "$PINNED" != "0" ] || roblox_ok; then FOUND="$p"; break; fi
    fi
    stop_spoofdpi
  done

  DEGRADED=0
  DEADLINE=0
  if [ -n "$FOUND" ]; then
    AVOID=""
    if [ "$PINNED" != "0" ]; then
      log "sabit alternatif $FOUND çalışıyor (doğrulama yapılmıyor)"
    else
      echo "$FOUND" > "$STATE_FILE"
      log "alternatif $FOUND çalışıyor, Roblox'a ulaşıldı"
    fi
  else
    # Hiçbiri doğrulanamadı (Roblox tarafı arızalı olabilir): yine de ilkini açık tut, sonra yeniden tara
    FOUND="${ORDER[0]}"
    DEGRADED=1
    DEADLINE=$(( $(date +%s) + DEGRADED_WAIT ))
    log "hiçbir alternatif doğrulanamadı; $FOUND ile devam, $DEGRADED_WAIT sn sonra yeniden taranacak"
    start_spoofdpi "$FOUND"
    wait_ready
  fi

  if [ "$MOD" = "http" ] && kill -0 "$SPID" 2>/dev/null; then set_proxy; fi

  # --- İzleme ---
  FAILS=0
  while true; do
    nap "$CHECK_EVERY"
    if ! kill -0 "$SPID" 2>/dev/null; then
      log "spoofdpi beklenmedik şekilde kapandı"
      break
    fi
    if [ "$DEGRADED" = "1" ]; then
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then log "yeniden taranıyor"; break; fi
    elif [ "$PINNED" = "0" ]; then
      if roblox_ok; then
        FAILS=0
      elif internet_ok; then
        FAILS=$((FAILS + 1))
        if [ "$FAILS" -ge 2 ]; then
          log "alternatif $FOUND'da Roblox bağlantısı koptu, diğerleri denenecek"
          AVOID="$FOUND"
          break
        fi
      else
        FAILS=0   # internetin kendisi yok: alternatiflere dokunma
      fi
    fi
  done

  clear_proxy
  stop_spoofdpi
done
