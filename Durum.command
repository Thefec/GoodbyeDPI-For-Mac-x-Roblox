#!/bin/bash
# GoodbyeDPI-Mac DURUM: her şeyin çalışıp çalışmadığını tek ekranda gösterir.
# Çift tıkla. Sorun varsa bu ekranın fotoğrafını gönder.

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
code_ok() { case "$1" in [234][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

echo "=============================================="
echo "   GoodbyeDPI-Mac DURUM   ($(date '+%F %T'))"
echo "=============================================="

# Servis
if launchctl print system/com.goodbyedpi.mac 2>/dev/null | grep -q 'state = running'; then
  ok "Arka plan servisi çalışıyor"
elif [ -f /Library/LaunchDaemons/com.goodbyedpi.mac.plist ]; then
  bad "Servis kurulu ama çalışmıyor (Yeniden-Baslat.command)"
else
  bad "Servis kurulu değil (Kur.command)"
fi

# DNS
ip="$(dig +short +time=2 +tries=1 A clientsettings.roblox.com @127.0.0.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)"
if [ -n "$ip" ]; then ok "Şifreli DNS çalışıyor ($ip)"; else bad "Şifreli DNS (dnscrypt-proxy) yanıt vermiyor"; fi
sys="$(dig +short +time=2 +tries=1 A clientsettings.roblox.com 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)"
if [ -n "$sys" ] && [ "$sys" != "195.175.254.2" ]; then ok "Sistem DNS doğru adres veriyor ($sys)"; else bad "Sistem DNS engelli adres veriyor (${sys:-yanıt yok})"; fi

# Roblox uygulaması yolu (proxy'siz)
c1="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 8 https://clientsettings.roblox.com 2>/dev/null)"
if code_ok "$c1"; then ok "Roblox uygulaması bağlanabilir (clientsettings: $c1)"; else bad "Roblox uygulaması bağlanamıyor (clientsettings: $c1)"; fi

# Tarayıcı yolu (SpoofDPI proxy'si)
c2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x http://127.0.0.1:8080 https://www.roblox.com 2>/dev/null)"
if code_ok "$c2"; then ok "Tarayıcı yolu çalışıyor (www.roblox.com: $c2)"; else bad "Tarayıcı yolu çalışmıyor (www.roblox.com: $c2)"; fi

echo
echo "Son olaylar:"
grep -E "başladı|çalışıyor|doğrulanamadı|koptu|yeniden|DNS|aktarıcı|doğrudan|python|internet yok" /var/log/goodbyedpi.log 2>/dev/null | tail -n 12 | sed 's/^/  /'
echo
read -r -p "Çıkmak için Enter'a bas..." _
