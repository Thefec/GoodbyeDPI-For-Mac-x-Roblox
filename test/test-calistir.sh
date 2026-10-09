#!/bin/bash
# dosyalar/calistir.sh için otomatik test.
# macOS gerektirmez: spoofdpi, python3 (aktarıcı), curl, nc, dig, pfctl ve networksetup'ın SAHTELERİ kullanılır.
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

# Sahte python3: "-c" ile çağrılırsa kullanılabilirlik kontrolü; yoksa aktarıcı gibi davranır
cat > "$T/fakebin/python3" <<'EOF'
#!/bin/bash
if [ "$1" = "-c" ]; then [ ! -f "$GDPI_T/no_python" ]; exit $?; fi
echo "$2" > "$GDPI_T/relay"
echo "RELAY start strateji=$2" >> "$GDPI_T/out.log"
trap 'rm -f "$GDPI_T/relay"; exit 0' TERM
while true; do sleep 0.2; done
EOF

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url=""; proxy=0
while [ $# -gt 0 ]; do
  case "$1" in
    -x) proxy=1; shift ;;
    -o|-w|--connect-timeout|--max-time|--noproxy) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in
  *captive.apple.com*)
    if [ "$(cat "$GDPI_T/internet" 2>/dev/null)" = "down" ]; then printf '000'; exit 28; fi
    printf '200'; exit 0 ;;
esac
if [ "$proxy" = "1" ]; then
  act="$(cat "$GDPI_T/active" 2>/dev/null)"
  ok="$(cat "$GDPI_T/ok_profile" 2>/dev/null)"
  if [ -n "$act" ] && [ "$act" = "$ok" ]; then printf '200'; exit 0; fi
  printf '000'; exit 28
fi
# Uygulama yolu (proxy'siz)
need="$(cat "$GDPI_T/app_need" 2>/dev/null)"
dns_set=0; [ "$(cat "$GDPI_T/ns_dns_Wi-Fi" 2>/dev/null)" = "127.0.0.1" ] && dns_set=1
case "$need" in
  direct) printf '200'; exit 0 ;;
  dns) [ "$dns_set" = 1 ] && { printf '200'; exit 0; } ;;
  relay*)
    want="${need#relay}"
    if [ "$dns_set" = 1 ] && [ -f "$GDPI_T/pf_on" ] && [ "$(cat "$GDPI_T/relay" 2>/dev/null)" = "$want" ]; then
      printf '200'; exit 0
    fi ;;
esac
printf '000'; exit 28
EOF

cat > "$T/fakebin/nc" <<'EOF'
#!/bin/bash
port="${*: -1}"
if [ "$port" = "8443" ]; then [ -f "$GDPI_T/relay" ]; else [ -f "$GDPI_T/active" ]; fi
EOF

cat > "$T/fakebin/dig" <<'EOF'
#!/bin/bash
if [ -f "$GDPI_T/dnscrypt_up" ]; then echo "titanium.roblox.com."; echo "128.116.21.3"; fi
EOF

cat > "$T/fakebin/pfctl" <<'EOF'
#!/bin/bash
echo "PF: $*" >> "$GDPI_T/out.log"
case "$*" in
  "-s nat") echo 'rdr-anchor "com.apple/*" all' ;;
  *"-f -"*) cat > "$GDPI_T/pf_rules"; touch "$GDPI_T/pf_on" ;;
  *"-F all"*) rm -f "$GDPI_T/pf_on" ;;
  "-E") echo "pf enabled" >&2; echo "Token : 4242" >&2; touch "$GDPI_T/pf_enabled" ;;
  *"-X"*) rm -f "$GDPI_T/pf_enabled" ;;
esac
EOF

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/dscacheutil"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/killall"

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
  -getdnsservers)
    k="$(key dns "$2")"
    if [ -f "$k" ]; then tr ' ' '\n' < "$k"; else echo "There aren't any DNS Servers set on $2."; fi ;;
  -setdnsservers)
    k="$(key dns "$2")"; shift 2
    if [ "$1" = "empty" ]; then rm -f "$k"; else echo "$*" > "$k"; fi ;;
esac
EOF
chmod +x "$T"/fakebin/*

export PATH="$T/fakebin:$PATH" GDPI_BIN="$T/fakebin/spoofdpi" GDPI_CONF_DIR="$T/conf" \
       GDPI_PYTHON="$T/fakebin/python3" GDPI_RELAY="relay.py" \
       GDPI_CHECK_EVERY=1 GDPI_RETRY_WAIT=1 GDPI_DEGRADED_WAIT=3

# --- Yardımcılar ---
PASS=0; FAIL=0
check() { local desc="$1"; shift; if "$@"; then echo "  ok    $desc"; PASS=$((PASS + 1)); else echo "  FAIL  $desc"; FAIL=$((FAIL + 1)); fi; }
not() { ! "$@"; }
log_has() { grep -q -- "$1" "$T/out.log"; }
line_of() { grep -n -- "$1" "$T/out.log" | head -n 1 | cut -d: -f1; }
before() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
first_try_is() { grep -m1 'deneniyor' "$T/out.log" | grep -q "alternatif $1 deneniyor"; }
first_try_after_drop() { awk '/koptu/{f=1;next} f && /alternatif [0-9] deneniyor/{print; exit}' "$T/out.log"; }
dropped_not_retried_first() {
  local l; l="$(first_try_after_drop)"
  [ -n "$l" ] && ! echo "$l" | grep -q "alternatif 3 deneniyor"
}
wait_for_log() { local _; for _ in $(seq 1 $(( $2 * 5 ))); do log_has "$1" && return 0; sleep 0.2; done; return 1; }
web_state() { head -n 1 "$T/ns_webproxy_Wi-Fi" 2>/dev/null; }
dns_of() { cat "$T/ns_dns_Wi-Fi" 2>/dev/null || echo "yok"; }
last_profile() { cat "$T/conf/son-profil" 2>/dev/null; }
reset_env() {
  rm -f "$T"/out.log "$T"/active "$T"/relay "$T"/ns_* "$T"/conf/* "$T"/internet "$T"/pf_* "$T"/no_python
  : > "$T/out.log"
  touch "$T/dnscrypt_up"; echo dns > "$T/app_need"
  printf 'PROFIL=otomatik\n' > "$T/user.conf"
}
start() { bash "$SCRIPT" "$T/user.conf" >> "$T/out.log" 2>&1 & DPID=$!; }
stop() { kill -TERM "$DPID"; wait "$DPID"; RC=$?; }
rc_zero() { [ "$RC" = "0" ]; }
eq() { [ "$1" = "$2" ]; }
exists() { [ -e "$1" ]; }

echo "A) tarayıcı: 1 ve 2 başarısız, 3 çalışıyor; DNS açılıyor, kapanınca eski DNS geri geliyor"
reset_env; echo 3 > "$T/ok_profile"; echo "192.168.1.1" > "$T/ns_dns_Wi-Fi"
start; sleep 4
RUNNING_PROXY="$(web_state)"; RUNNING_LAST="$(last_profile)"; RUNNING_DNS="$(dns_of)"
stop
check "3. alternatif seçildi"                     log_has "alternatif 3 çalışıyor"
check "4. alternatif denenmedi (3'te durdu)"      not log_has "alternatif 4 deneniyor"
check "son çalışan kaydedildi (3)"                eq "$RUNNING_LAST" "3"
check "proxy çalışırken açık"                     eq "$RUNNING_PROXY" "Enabled: Yes"
check "proxy kapanınca kapalı"                    eq "$(web_state)" "Enabled: No"
check "proxy yalnızca çalışan bulununca açıldı"   before "alternatif 3 çalışıyor" "NS: -setwebproxy Wi-Fi"
check "çalışırken DNS 127.0.0.1"                  eq "$RUNNING_DNS" "127.0.0.1"
check "kapanınca eski DNS geri geldi"             eq "$(dns_of)" "192.168.1.1"
check "uygulama doğrudan bağlandı, aktarıcı yok"  log_has "doğrudan bağlanabiliyor"
check "aktarıcı başlatılmadı"                     not log_has "RELAY start"
check "sinyalle temiz çıkış"                      rc_zero

echo "B) yeniden başlatma: son çalışan ilk denenmeli"
: > "$T/out.log"; start; sleep 2.5; stop
check "ilk denenen 3"                             first_try_is 3

echo "C) çalışırken tarayıcı bağlantısı koptu: 3 en sona atılmalı, 5 bulunmalı"
reset_env; echo 3 > "$T/ok_profile"; echo 3 > "$T/conf/son-profil"
start; sleep 2; echo 5 > "$T/ok_profile"; sleep 8
C_LAST="$(last_profile)"; stop
check "kopma fark edildi"                         log_has "Roblox bağlantısı koptu"
check "kopan 3 hemen tekrar denenmedi"            dropped_not_retried_first
check "5 bulundu ve kaydedildi"                   eq "$C_LAST" "5"

echo "D) hiçbir alternatif çalışmıyor: 1 ile devam, sonra yeniden tara"
reset_env; echo none > "$T/ok_profile"
export GDPI_DEGRADED_WAIT=6
start
wait_for_log "hiçbir alternatif doğrulanamadı" 20; D_MSG=$?
sleep 2.5; D_PROXY="$(web_state)"
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
reset_env; printf 'PROFIL=5\n' > "$T/user.conf"; echo none > "$T/ok_profile"
start; sleep 2.5; F_PROXY="$(web_state)"; stop
check "sabit alternatif mesajı"                   log_has "sabit alternatif 5 çalışıyor"
check "yalnızca 5 başlatıldı"                     eq "$(grep -c '^SPOOFDPI' "$T/out.log")" "1"
check "proxy açıldı"                              eq "$F_PROXY" "Enabled: Yes"
check "son-profil yazılmadı"                      not test -f "$T/conf/son-profil"

echo "G) uygulama doğrudan bağlanamıyor: aktarıcı 1 başarısız, 2 çalışıyor"
reset_env; echo 1 > "$T/ok_profile"; echo relay2 > "$T/app_need"
start; sleep 4
G_RELAY="$(cat "$T/relay" 2>/dev/null)"; G_PF=0; [ -f "$T/pf_on" ] && G_PF=1
stop
check "aktarıcı 1 denendi"                        log_has "uygulama aktarıcısı 1 deneniyor"
check "aktarıcı 2 seçildi"                        log_has "uygulama aktarıcısı 2 çalışıyor"
check "çalışırken aktarıcı 2 açık"                eq "$G_RELAY" "2"
check "çalışırken pf kuralı yüklü"                eq "$G_PF" "1"
check "pf kuralı yalnızca Roblox IP'leri"         grep -q 'table <gdpi_roblox> persist { 128.116.0.0/17' "$T/pf_rules"
check "pf kuralı aktarıcının kendisini dışlıyor"  grep -q 'user { != nobody }' "$T/pf_rules"
check "kapanınca pf kuralı kaldırıldı"            not exists "$T/pf_on"
check "kapanınca pf referansı bırakıldı"          not exists "$T/pf_enabled"
check "kapanınca aktarıcı durdu"                  not exists "$T/relay"

echo "H) ayar dosyasına kötü niyetli değer: komut çalışmamalı, varsayılana düşmeli"
reset_env; echo 3 > "$T/ok_profile"
printf 'PROFIL=$(touch %s/pwned)\n' "$T" > "$T/user.conf"
start; sleep 3; stop
check "komut enjeksiyonu yok"                     not test -e "$T/pwned"
check "otomatik moda düştü"                       log_has "başladı: alternatif=otomatik"

echo "I) şifreli DNS yok: DNS'e dokunmamalı, önceki çalışmadan kalan 127.0.0.1 temizlenmeli"
reset_env; rm -f "$T/dnscrypt_up"; echo 1 > "$T/ok_profile"; echo direct > "$T/app_need"
echo "127.0.0.1" > "$T/ns_dns_Wi-Fi"
start; sleep 3; I_DNS="$(dns_of)"; stop
check "uyarı kaydedildi"                          log_has "şifreli DNS çalışmıyor"
check "kalan 127.0.0.1 temizlendi"                eq "$I_DNS" "yok"
check "DNS 127.0.0.1'e çevrilmedi"                not log_has "NS: -setdnsservers Wi-Fi 127.0.0.1"

echo "J) şifreli DNS çalışırken çöktü: internet bozulmasın diye eski DNS'e dönmeli"
reset_env; echo 1 > "$T/ok_profile"; echo direct > "$T/app_need"; echo "8.8.8.8 1.1.1.1" > "$T/ns_dns_Wi-Fi"
start; sleep 2.5; J_BEFORE="$(dns_of)"; rm -f "$T/dnscrypt_up"; sleep 2.5; J_AFTER="$(dns_of)"; stop
check "önce 127.0.0.1"                            eq "$J_BEFORE" "127.0.0.1"
check "çökünce eski DNS (iki sunucu) geri geldi"  eq "$J_AFTER" "8.8.8.8 1.1.1.1"

echo "K) uygulama için hiçbir yol yok: aktarıcı ve pf kapalı kalmalı, tarayıcı yine çalışmalı"
reset_env; echo 2 > "$T/ok_profile"; echo none > "$T/app_need"
start; sleep 5; K_PF=0; [ -f "$T/pf_on" ] && K_PF=1; K_RELAY=0; [ -f "$T/relay" ] && K_RELAY=1; stop
check "üç strateji denendi"                       log_has "uygulama aktarıcısı 3 deneniyor"
check "yol doğrulanamadı mesajı"                  log_has "uygulaması için yol doğrulanamadı"
check "pf kapalı"                                 eq "$K_PF" "0"
check "aktarıcı kapalı"                           eq "$K_RELAY" "0"
check "tarayıcı alternatifi yine seçildi"         log_has "alternatif 2 çalışıyor"

echo "L) python yok: aktarıcı denenmemeli"
reset_env; echo 1 > "$T/ok_profile"; echo relay1 > "$T/app_need"; touch "$T/no_python"
start; sleep 2.5; stop
check "python uyarısı"                            log_has "python3 yok"
check "aktarıcı başlatılmadı"                     not log_has "RELAY start"

echo "M) açılışta şifreli DNS geç hazır oldu: Roblox uygulaması yolu beklemeden yeniden taranmalı"
reset_env; rm -f "$T/dnscrypt_up"; echo 1 > "$T/ok_profile"; echo dns > "$T/app_need"
export GDPI_DEGRADED_WAIT=300
start; sleep 3; touch "$T/dnscrypt_up"
wait_for_log "doğrudan bağlanabiliyor" 15; M_OK=$?
stop
export GDPI_DEGRADED_WAIT=3
check "DNS gelince yeniden tarandı"               log_has "DNS durumu değişti"
check "uygulama yolu 300 sn beklemeden bulundu"   eq "$M_OK" "0"

echo
echo "Sonuç: $PASS geçti, $FAIL kaldı"
[ "$FAIL" = "0" ]
