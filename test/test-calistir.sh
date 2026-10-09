#!/bin/bash
# dosyalar/calistir.sh için otomatik seçim testi.
# macOS gerektirmez: spoofdpi, curl, nc ve networksetup'ın SAHTELERİ kullanılır.
# Çalıştır:  bash test/test-calistir.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/dosyalar/calistir.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin" "$T/conf"
export GDPI_T="$T"

# --- Sahte araçlar (durum $GDPI_T içinde tutulur) ---
cat > "$T/fakebin/spoofdpi" <<'EOF'
#!/bin/bash
cfg=""
while [ $# -gt 0 ]; do [ "$1" = "--config" ] && cfg="$2"; shift; done
n="$(basename "$cfg" .toml | sed 's/profil-//')"
echo "$n" > "$GDPI_T/active"
echo "SPOOFDPI start profil=$n" >> "$GDPI_T/out.log"
trap 'rm -f "$GDPI_T/active"; exit 0' TERM
while true; do sleep 0.2; done
EOF

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url=""
while [ $# -gt 0 ]; do
  case "$1" in -x) shift ;; esac
  url="$1"; shift
done
case "$url" in
  *captive.apple.com*)
    if [ "$(cat "$GDPI_T/internet" 2>/dev/null)" = "down" ]; then printf '000'; exit 28; fi
    printf '200'; exit 0 ;;
esac
act="$(cat "$GDPI_T/active" 2>/dev/null)"
ok="$(cat "$GDPI_T/ok_profile" 2>/dev/null)"
if [ -n "$act" ] && [ "$act" = "$ok" ]; then printf '200'; exit 0; fi
printf '000'; exit 28
EOF

cat > "$T/fakebin/nc" <<'EOF'
#!/bin/bash
[ -f "$GDPI_T/active" ]
EOF

cat > "$T/fakebin/networksetup" <<'EOF'
#!/bin/bash
echo "NS: $*" >> "$GDPI_T/out.log"
key() { echo "$GDPI_T/ns_$1_$(echo "$2" | tr ' /' '__')"; }
case "$1" in
  -listallnetworkservices)
    echo "An asterisk (*) denotes that a network service is disabled."
    echo "Wi-Fi"; echo "*Thunderbolt Bridge" ;;
  -getwebproxy|-getsecurewebproxy)
    k="$(key "${1#-get}" "$2")"
    if [ -f "$k" ]; then cat "$k"; else printf 'Enabled: No\nServer: \nPort: 0\n'; fi ;;
  -setwebproxy|-setsecurewebproxy)
    k="$(key "${1#-set}" "$2")"
    printf 'Enabled: Yes\nServer: %s\nPort: %s\n' "$3" "$4" > "$k" ;;
  -setwebproxystate|-setsecurewebproxystate)
    k="$(key "$(echo "${1#-set}" | sed 's/state$//')" "$2")"
    if [ -f "$k" ] && [ "$3" = "off" ]; then
      sed 's/^Enabled: Yes/Enabled: No/' "$k" > "$k.tmp" && mv "$k.tmp" "$k"
    fi ;;
esac
EOF
chmod +x "$T"/fakebin/*

export PATH="$T/fakebin:$PATH" GDPI_BIN="$T/fakebin/spoofdpi" GDPI_CONF_DIR="$T/conf" \
       GDPI_CHECK_EVERY=1 GDPI_RETRY_WAIT=1 GDPI_DEGRADED_WAIT=3 GDPI_STARTUP_WAIT=1

# --- Yardımcılar ---
PASS=0; FAIL=0
check() { local desc="$1"; shift; if "$@"; then echo "  ok    $desc"; PASS=$((PASS + 1)); else echo "  FAIL  $desc"; FAIL=$((FAIL + 1)); fi; }
not() { ! "$@"; }
log_has() { grep -q -- "$1" "$T/out.log"; }
line_of() { grep -n -- "$1" "$T/out.log" | head -n 1 | cut -d: -f1; }
before() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
first_try_is() { grep -m1 'deneniyor' "$T/out.log" | grep -q "alternatif $1 deneniyor"; }
# "koptu" satırından sonra denenen ilk alternatif, kopan 3 olmamalı
first_try_after_drop() { awk '/koptu/{f=1;next} f && /deneniyor/{print; exit}' "$T/out.log"; }
dropped_not_retried_first() {
  local l; l="$(first_try_after_drop)"
  [ -n "$l" ] && ! echo "$l" | grep -q "alternatif 3 deneniyor"
}
wait_for_log() { local _; for _ in $(seq 1 $(( $2 * 5 ))); do log_has "$1" && return 0; sleep 0.2; done; return 1; }
web_state() { head -n 1 "$T/ns_webproxy_Wi-Fi" 2>/dev/null; }
last_profile() { cat "$T/conf/son-profil" 2>/dev/null; }
reset_env() { rm -f "$T"/out.log "$T"/active "$T"/ns_* "$T"/conf/son-profil "$T"/internet; : > "$T/out.log"; }
start() { bash "$SCRIPT" "$T/user.conf" >> "$T/out.log" 2>&1 & DPID=$!; }
stop() { kill -TERM "$DPID"; wait "$DPID"; RC=$?; }
rc_zero() { [ "$RC" = "0" ]; }
eq() { [ "$1" = "$2" ]; }

echo "A) 1 ve 2 başarısız, 3 çalışıyor"
reset_env; printf 'PROFIL=otomatik\nMOD=http\n' > "$T/user.conf"; echo 3 > "$T/ok_profile"
start; sleep 4
RUNNING_PROXY="$(web_state)"; RUNNING_LAST="$(last_profile)"
stop
check "3. alternatif seçildi"                     log_has "alternatif 3 çalışıyor"
check "4. alternatif denenmedi (3'te durdu)"      not log_has "alternatif 4 deneniyor"
check "son çalışan kaydedildi (3)"                eq "$RUNNING_LAST" "3"
check "proxy çalışırken açık"                     eq "$RUNNING_PROXY" "Enabled: Yes"
check "proxy kapanınca kapalı"                    eq "$(web_state)" "Enabled: No"
check "proxy yalnızca çalışan bulununca açıldı"   before "alternatif 3 çalışıyor" "NS: -setwebproxy Wi-Fi"
check "sinyalle temiz çıkış"                      rc_zero

echo "B) yeniden başlatma: son çalışan ilk denenmeli"
: > "$T/out.log"; start; sleep 2.5; stop
check "ilk denenen 3"                             first_try_is 3

echo "C) çalışırken bağlantı koptu: 3 en sona atılmalı, 5 bulunmalı"
reset_env; echo 3 > "$T/ok_profile"; echo 3 > "$T/conf/son-profil"
start; sleep 2; echo 5 > "$T/ok_profile"; sleep 8
C_LAST="$(last_profile)"; stop
check "kopma fark edildi"                         log_has "Roblox bağlantısı koptu"
check "kopan 3 hemen tekrar denenmedi"            dropped_not_retried_first
check "5 bulundu ve kaydedildi"                   eq "$C_LAST" "5"

echo "D) hiçbiri çalışmıyor: 1 ile devam, sonra yeniden tara"
reset_env; echo none > "$T/ok_profile"
export GDPI_DEGRADED_WAIT=6
start
wait_for_log "hiçbir alternatif doğrulanamadı" 20; D_MSG=$?
sleep 2.5; D_PROXY="$(web_state)"   # bekleme penceresinin ortasında oku
wait_for_log "yeniden taranıyor" 15; D_RESCAN=$?
stop
export GDPI_DEGRADED_WAIT=3
check "doğrulanamadı mesajı"                      eq "$D_MSG" "0"
check "yine de proxy açık (1. alternatifle)"      eq "$D_PROXY" "Enabled: Yes"
check "yeniden tarama yapıldı"                    eq "$D_RESCAN" "0"
check "bozuk alternatif son-profil'e yazılmadı"   not test -f "$T/conf/son-profil"

echo "E) internet yok: alternatif denememeli"
reset_env; echo 3 > "$T/ok_profile"; echo down > "$T/internet"
start; sleep 3; E_STARTED="$(grep -c '^SPOOFDPI' "$T/out.log")"; stop
check "spoofdpi hiç başlatılmadı"                 eq "$E_STARTED" "0"
check "'internet yok' kaydedildi"                 log_has "internet yok"

echo "F) sabit alternatif (PROFIL=5): doğrulama yok"
reset_env; printf 'PROFIL=5\nMOD=http\n' > "$T/user.conf"; echo none > "$T/ok_profile"
start; sleep 2.5; F_PROXY="$(web_state)"; stop
check "sabit alternatif mesajı"                   log_has "sabit alternatif 5 çalışıyor"
check "yalnızca 5 başlatıldı"                     eq "$(grep -c '^SPOOFDPI' "$T/out.log")" "1"
check "proxy açıldı"                              eq "$F_PROXY" "Enabled: Yes"
check "son-profil yazılmadı"                      not test -f "$T/conf/son-profil"

echo "G) tun modu: sistem proxy'sine dokunmamalı"
reset_env; printf 'PROFIL=otomatik\nMOD=tun\n' > "$T/user.conf"; echo 2 > "$T/ok_profile"
start; sleep 4; stop
check "2. alternatif seçildi"                     log_has "alternatif 2 çalışıyor"
check "networksetup -set çağrılmadı"              not log_has "NS: -set"

echo "H) ayar dosyasına kötü niyetli değer: komut çalışmamalı, varsayılana düşmeli"
reset_env; echo 3 > "$T/ok_profile"
printf 'PROFIL=$(touch %s/pwned)\nMOD=http; id\n' "$T" > "$T/user.conf"
start; sleep 3; stop
check "komut enjeksiyonu yok"                     not test -e "$T/pwned"
check "otomatik moda düştü"                       log_has "alternatif=otomatik mod=http"

echo
echo "Sonuç: $PASS geçti, $FAIL kaldı"
[ "$FAIL" = "0" ]
