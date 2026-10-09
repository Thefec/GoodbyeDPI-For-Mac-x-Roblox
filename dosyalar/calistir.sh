#!/bin/bash
# GoodbyeDPI-Mac arka plan servisi. launchd tarafından root olarak, Mac açılışında çalıştırılır.
# Argüman 1: kullanıcının ayarlar.conf dosyasının yolu.
#
# Üç katman, her biri kendini sınar ve gerekmiyorsa devreye girmez:
#  1. DNS: operatör Roblox adreslerine sahte IP veriyor. Yerel şifreli DNS (dnscrypt-proxy, 127.0.0.1)
#     çalışıyorsa sistem DNS'i ona yönlendirilir; çalışmazsa eski DNS geri yüklenir (internet bozulmaz).
#  2. Roblox uygulaması: sistem proxy'sini kullanmaz. Doğrudan bağlanamıyorsa, yalnızca Roblox IP'lerine
#     giden trafik pf ile yerel aktarıcıya (roblox-relay.py) yönlendirilir; aktarıcı ClientHello'yu parçalar.
#     3 strateji sırayla denenir.
#  3. Tarayıcı: 8 SpoofDPI alternatifi sırayla denenir, Roblox'a bağlanan sistem proxy'si yapılır.
# Bağlantı koparsa yeniden taranır. macOS'un bash'i 3.2: bu betik ona uyumlu yazıldı.

USER_CONF="$1"
CONF_DIR="${GDPI_CONF_DIR:-/usr/local/etc/goodbyedpi}"
BIN="${GDPI_BIN:-/usr/local/libexec/goodbyedpi/spoofdpi}"
RELAY="${GDPI_RELAY:-/usr/local/libexec/goodbyedpi/roblox-relay.py}"
PYTHON="${GDPI_PYTHON:-/usr/bin/python3}"
STATE_FILE="$CONF_DIR/son-profil"
DNS_SAVE="$CONF_DIR/dns-yedek"
PF_TOKEN_FILE="$CONF_DIR/pf-token"
PF_ANCHOR="com.apple/goodbyedpi"

PORT=8080
RELAY_PORT=8443
TOTAL=8
RELAY_STRATEGIES="1 2 3"
CHECK_EVERY="${GDPI_CHECK_EVERY:-30}"       # sağlıklı çalışırken kontrol aralığı (sn)
RETRY_WAIT="${GDPI_RETRY_WAIT:-30}"         # internet yokken bekleme (sn)
DEGRADED_WAIT="${GDPI_DEGRADED_WAIT:-300}"  # bir katman doğrulanamazsa yeniden taramadan önce bekleme (sn)

# Tarayıcı yolu (SpoofDPI proxy'si üzerinden): hepsine erişilebilmeli
TEST_URLS=("https://www.roblox.com" "https://apis.roblox.com")
# Uygulama yolu (proxy'siz): Roblox uygulamasının açılışta ilk indirdiği ayarlar
APP_URLS=("https://clientsettings.roblox.com" "https://clientsettingscdn.roblox.com" "https://www.roblox.com" "https://setup.rbxcdn.com")
# Roblox'un IP blokları (AS22697). Yalnızca bunlara giden 443 trafiği aktarıcıya yönlendirilir.
ROBLOX_NETS="128.116.0.0/17, 103.140.28.0/23, 209.206.40.0/21"
# Roblox IP bloklarının dışında (CDN'lerde) duran adresler: indirici, ayarlar, oyun dosyaları.
# IP'leri şifreli DNS'ten çözülüp pf tablosuna eklenir (aktarıcı SNI'ya göre çalıştığı için paylaşılan CDN IP'leri sorun olmaz).
ROBLOX_HOSTS="www.roblox.com clientsettings.roblox.com clientsettingscdn.roblox.com setup.rbxcdn.com setup-aws.rbxcdn.com setup-cfly.rbxcdn.com
apis.roblox.com auth.roblox.com ecsv2.roblox.com assetdelivery.roblox.com gamejoin.roblox.com users.roblox.com thumbnails.roblox.com
tr.rbxcdn.com c0.rbxcdn.com c1.rbxcdn.com c2.rbxcdn.com c3.rbxcdn.com c4.rbxcdn.com c5.rbxcdn.com c6.rbxcdn.com c7.rbxcdn.com
t0.rbxcdn.com t1.rbxcdn.com t2.rbxcdn.com t3.rbxcdn.com t4.rbxcdn.com t5.rbxcdn.com t6.rbxcdn.com t7.rbxcdn.com"
# Proxy'siz, doğrudan internet var mı kontrolü
CONTROL_URL="http://captive.apple.com/hotspot-detect.html"

# --- Ayarlar (kullanıcı dosyası root olarak okunuyor: ÇALIŞTIRMA yok, yalnızca izinli değerler) ---
PINNED="0"      # 0 = otomatik, 1-8 = sabit alternatif
if [ -r "$USER_CONF" ]; then
  v="$(grep -E '^PROFIL=(otomatik|[1-8])[[:space:]]*$' "$USER_CONF" | tail -n 1 | cut -d= -f2 | tr -d '[:space:]')"
  if [ -n "$v" ] && [ "$v" != "otomatik" ]; then PINNED="$v"; fi
fi

SPID=""
RPID=""
AVOID=""      # bağlantısı kopan alternatif: yeniden taramada en sona alınır
DNS_STATE=""  # acik | kapali
APP_MODE=""   # direkt | aktarici-N | yok

log() { echo "$(date '+%F %T') $*"; }

# Sinyalle kesilebilen bekleme
nap() { sleep "$1" & wait "$!" 2>/dev/null; }

# Bir süreci kibarca, olmazsa zorla kapatır
kill_wait() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.3
    done
    kill -KILL "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
}

http_ok_code() {
  case "$1" in
    [234][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Ağ servisleri ---
list_services() { networksetup -listallnetworkservices 2>/dev/null | tail -n +2; }
enabled_services() { list_services | grep -v '^\*'; }   # başında * olanlar devre dışı

# ============================== 1. DNS ==============================
dnscrypt_ok() {
  dig +short +time=2 +tries=1 A clientsettings.roblox.com @127.0.0.1 2>/dev/null \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

flush_dns_cache() {
  dscacheutil -flushcache >/dev/null 2>&1
  killall -HUP mDNSResponder >/dev/null 2>&1
}

current_dns() { networksetup -getdnsservers "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

set_dns() {
  local svc cur
  enabled_services | while IFS= read -r svc; do
    cur="$(current_dns "$svc")"
    [ "$cur" = "127.0.0.1" ] && continue
    case "$cur" in *"aren't any"*|"") cur="empty" ;; esac
    if ! awk -F'\t' -v s="$svc" '$1==s {f=1} END {exit !f}' "$DNS_SAVE" 2>/dev/null; then
      printf '%s\t%s\n' "$svc" "$cur" >> "$DNS_SAVE"
    fi
    networksetup -setdnsservers "$svc" 127.0.0.1 >/dev/null 2>&1
  done
  flush_dns_cache
}

# Yalnızca 127.0.0.1'e çevrilmiş servisleri eski haline döndürür
restore_dns() {
  local svc cur saved
  list_services | sed 's/^\*//' | while IFS= read -r svc; do
    cur="$(current_dns "$svc")"
    [ "$cur" = "127.0.0.1" ] || continue
    saved="$(awk -F'\t' -v s="$svc" '$1==s {print $2; exit}' "$DNS_SAVE" 2>/dev/null)"
    [ -n "$saved" ] || saved="empty"
    # shellcheck disable=SC2086  # birden fazla sunucu olabilir, ayrı argüman olmalı
    networksetup -setdnsservers "$svc" $saved >/dev/null 2>&1
  done
  rm -f "$DNS_SAVE"
  flush_dns_cache
}

dns_update() {
  DNS_CHANGED=0
  if dnscrypt_ok; then
    set_dns
    if [ "$DNS_STATE" != "acik" ]; then log "şifreli DNS açık (127.0.0.1)"; DNS_STATE="acik"; DNS_CHANGED=1; fi
  else
    restore_dns
    if [ "$DNS_STATE" != "kapali" ]; then
      log "şifreli DNS çalışmıyor (dnscrypt-proxy); normal DNS kullanılıyor"
      DNS_STATE="kapali"
      DNS_CHANGED=1
    fi
  fi
}

# ======================= 2. Roblox uygulaması =======================
app_ok() {
  local url code
  for url in "${APP_URLS[@]}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null)"
    http_ok_code "$code" || return 1
  done
  return 0
}

pf_rules() {
  printf 'table <gdpi_roblox> persist { %s }\n' "$ROBLOX_NETS"
  printf 'rdr pass inet proto tcp from any to <gdpi_roblox> port 443 -> 127.0.0.1 port %s\n' "$RELAY_PORT"
  printf 'pass out quick route-to (lo0 127.0.0.1) inet proto tcp from any to <gdpi_roblox> port 443 user { != nobody } keep state\n'
}

pf_on() {
  # Ana kural kümesi yüklü değilse (com.apple/* çapaları yoksa) varsayılanı yükle
  if ! pfctl -s nat 2>/dev/null | grep -q 'com.apple'; then
    pfctl -q -f /etc/pf.conf >/dev/null 2>&1
  fi
  pf_rules | pfctl -q -a "$PF_ANCHOR" -f - >/dev/null 2>&1 || return 1
  pf_add_hosts
  if [ ! -s "$PF_TOKEN_FILE" ]; then
    pfctl -E 2>&1 | awk '/Token/ {print $NF}' > "$PF_TOKEN_FILE"
  fi
  return 0
}

# Roblox adreslerinin güncel IP'lerini pf tablosuna ekler (CDN IP'leri değişebilir; her kontrolde yenilenir)
pf_add_hosts() {
  local h ips
  # shellcheck disable=SC2086  # ROBLOX_HOSTS boşlukla ayrılmış liste
  for h in $ROBLOX_HOSTS; do
    ips="$(dig +short +time=2 +tries=1 A "$h" @127.0.0.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    [ -n "$ips" ] && pfctl -q -a "$PF_ANCHOR" -t gdpi_roblox -T add $ips >/dev/null 2>&1
  done
  return 0
}

pf_off() {
  pfctl -q -a "$PF_ANCHOR" -F all >/dev/null 2>&1
  if [ -s "$PF_TOKEN_FILE" ]; then
    pfctl -q -X "$(cat "$PF_TOKEN_FILE")" >/dev/null 2>&1
  fi
  rm -f "$PF_TOKEN_FILE"
}

start_relay() {
  "$PYTHON" "$RELAY" "$1" &
  RPID=$!
  for _ in $(seq 1 20); do
    kill -0 "$RPID" 2>/dev/null || return 1
    nc -z 127.0.0.1 "$RELAY_PORT" >/dev/null 2>&1 && return 0
    nap 0.25
  done
  return 1
}

stop_relay() { kill_wait "$RPID"; RPID=""; }

app_teardown() { pf_off; stop_relay; }

app_setup() {
  local s
  APP_MODE="yok"
  # Önce aktarıcı: doğrudan bağlantı curl'da geçse bile Roblox uygulamasının bağlantısı DPI'ye
  # takılabiliyor (gerçek Mac'te görüldü: curl 200, uygulama SslConnectFail). Aktarıcı her durumda daha güvenli.
  if "$PYTHON" -c 'import asyncio' >/dev/null 2>&1; then
    for s in $RELAY_STRATEGIES; do
      log "uygulama aktarıcısı $s deneniyor"
      if start_relay "$s" && pf_on && app_ok; then
        APP_MODE="aktarici-$s"
        log "uygulama aktarıcısı $s çalışıyor, Roblox uygulaması bağlanabilir"
        return
      fi
      app_teardown
    done
  else
    log "python3 yok; Roblox uygulaması aktarıcısı çalıştırılamıyor (xcode-select --install)"
  fi
  if app_ok; then
    APP_MODE="direkt"
    log "Roblox uygulaması doğrudan bağlanabiliyor (aktarıcı olmadan)"
    return
  fi
  log "Roblox uygulaması için yol doğrulanamadı; $DEGRADED_WAIT sn sonra yeniden denenecek"
}

# ========================= 3. Tarayıcı (SpoofDPI) =========================
set_proxy() {
  local svc cur en srv
  enabled_services | while IFS= read -r svc; do
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
clear_proxy() {
  local svc kind server
  list_services | sed 's/^\*//' | while IFS= read -r svc; do
    for kind in webproxy securewebproxy; do
      server="$(networksetup -get${kind} "$svc" 2>/dev/null | awk -F': ' '/^Server/{print $2}')"
      if [ "$server" = "127.0.0.1" ]; then
        networksetup -set${kind}state "$svc" off >/dev/null 2>&1
      fi
    done
  done
}

start_spoofdpi() {
  "$BIN" --config "$CONF_DIR/profil-$1.toml" --no-tui --log-level warn &
  SPID=$!
}

stop_spoofdpi() { kill_wait "$SPID"; SPID=""; }

wait_ready() {
  for _ in $(seq 1 20); do
    kill -0 "$SPID" 2>/dev/null || return 1
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && return 0
    nap 0.5
  done
  return 1
}

# Roblox adreslerine proxy üzerinden ulaşılabiliyor mu (2xx-4xx yanıt = ulaşıldı)
roblox_ok() {
  local url code
  for url in "${TEST_URLS[@]}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 -x "http://127.0.0.1:$PORT" "$url" 2>/dev/null)"
    http_ok_code "$code" || return 1
  done
  return 0
}

# Proxy'siz doğrudan internet var mı
internet_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 4 --max-time 6 "$CONTROL_URL" 2>/dev/null)"
  case "$code" in
    [23][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# Deneme sırası: önce son çalışan, sonra 1..8
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

browser_setup() {
  local p
  build_order
  FOUND=""
  BROWSER_DEGRADED=0
  for p in "${ORDER[@]}"; do
    log "alternatif $p deneniyor"
    start_spoofdpi "$p"
    if wait_ready; then
      if [ "$PINNED" != "0" ] || roblox_ok; then FOUND="$p"; break; fi
    fi
    stop_spoofdpi
  done

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
    BROWSER_DEGRADED=1
    log "hiçbir alternatif doğrulanamadı; $FOUND ile devam, $DEGRADED_WAIT sn sonra yeniden taranacak"
    start_spoofdpi "$FOUND"
    wait_ready
  fi
  if kill -0 "$SPID" 2>/dev/null; then set_proxy; fi
}

# ============================== Ana döngü ==============================
on_term() {
  log "kapatılıyor"
  clear_proxy
  stop_spoofdpi
  app_teardown
  restore_dns
  exit 0
}
trap on_term TERM INT

log "başladı: alternatif=$( [ "$PINNED" = "0" ] && echo otomatik || echo "$PINNED" )"
# Önceki çalışmadan kalmış ayarlar varsa temizle
clear_proxy
app_teardown

OFFLINE_LOGGED=0
while true; do
  dns_update

  # Doğrudan internet yoksa alternatifleri boşuna döndürme
  if ! internet_ok; then
    if [ "$OFFLINE_LOGGED" = "0" ]; then log "internet yok, bekleniyor"; OFFLINE_LOGGED=1; fi
    nap "$RETRY_WAIT"
    continue
  fi
  OFFLINE_LOGGED=0

  app_setup
  browser_setup

  DEADLINE=0
  if [ "$BROWSER_DEGRADED" = "1" ] || [ "$APP_MODE" = "yok" ]; then
    DEADLINE=$(( $(date +%s) + DEGRADED_WAIT ))
  fi

  # --- İzleme ---
  FAILS=0
  APP_FAILS=0
  while true; do
    nap "$CHECK_EVERY"
    dns_update
    if [ -n "$RPID" ]; then pf_add_hosts; fi
    if [ "$DNS_CHANGED" = "1" ] && [ "$APP_MODE" = "yok" ]; then
      log "DNS durumu değişti, Roblox uygulaması yolu yeniden taranacak"
      break
    fi
    if ! kill -0 "$SPID" 2>/dev/null; then
      log "spoofdpi beklenmedik şekilde kapandı"
      break
    fi
    if [ -n "$RPID" ] && ! kill -0 "$RPID" 2>/dev/null; then
      log "uygulama aktarıcısı beklenmedik şekilde kapandı"
      break
    fi
    if [ "$DEADLINE" != "0" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
      log "yeniden taranıyor"
      break
    fi

    # Tarayıcı yolu
    if [ "$PINNED" = "0" ] && [ "$BROWSER_DEGRADED" = "0" ]; then
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

    # Uygulama yolu
    if [ "$APP_MODE" != "yok" ]; then
      if app_ok; then
        APP_FAILS=0
      elif internet_ok; then
        APP_FAILS=$((APP_FAILS + 1))
        if [ "$APP_FAILS" -ge 2 ]; then
          log "Roblox uygulaması bağlantısı koptu ($APP_MODE), yeniden taranacak"
          break
        fi
      else
        APP_FAILS=0
      fi
    fi
  done

  clear_proxy
  stop_spoofdpi
  app_teardown
done
