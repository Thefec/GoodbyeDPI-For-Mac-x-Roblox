#!/bin/bash
# GoodbyeDPI-Mac KURULUM: Mac açılışında arka planda otomatik çalışır.
# Çift tıkla (ya da Terminal'de ./Kur.command). Bir kez yapmak yeterli; güncellemek için de bunu çalıştır.

cd "$(dirname "$0")" || exit 1
SRC="$(pwd)/dosyalar"

pause_exit() { echo; read -r -p "Çıkmak için Enter'a bas..." _; exit "${1:-0}"; }

echo "=============================================="
echo "   GoodbyeDPI-Mac KURULUM  (v0.2.2)"
echo "=============================================="
echo

# --- Homebrew ---
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew bulunamadı. Önce https://brew.sh adresindeki komutla kur,"
  echo "sonra bu dosyayı tekrar çalıştır."
  pause_exit 1
fi
BREW="$(command -v brew)"

# --- Paketler (eski macOS'ta derleme birkaç dakika sürebilir) ---
for pkg in libpcap spoofdpi dnscrypt-proxy; do
  if ! brew list "$pkg" >/dev/null 2>&1; then
    echo "$pkg kuruluyor (birkaç dakika sürebilir)..."
    brew install "$pkg" || { echo "$pkg kurulamadı."; pause_exit 1; }
  fi
done
SPOOFDPI="$(command -v spoofdpi)"
[ -n "$SPOOFDPI" ] || SPOOFDPI="$(brew --prefix)/bin/spoofdpi"

# --- python3 (Roblox uygulaması aktarıcısı için; Apple'ın komut satırı araçlarıyla gelir) ---
if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/python3 -c 'import asyncio' >/dev/null 2>&1; then
  echo "UYARI: python3 bulunamadı. Açılan pencerede 'Yükle'ye bas, bitince Kur.command'ı yeniden çalıştır."
  xcode-select --install >/dev/null 2>&1
fi

# --- Kullanıcı ayar dosyası (yalnızca PROFIL korunur; eski MOD ayarı kaldırıldı) ---
USER_DIR="$HOME/Library/Application Support/GoodbyeDPI"
USER_CONF="$USER_DIR/ayarlar.conf"
mkdir -p "$USER_DIR"
OLD_PROFIL="$(grep -E '^PROFIL=(otomatik|[1-8])[[:space:]]*$' "$USER_CONF" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
cp "$SRC/ayarlar.conf" "$USER_CONF"
if [ -n "$OLD_PROFIL" ] && [ "$OLD_PROFIL" != "PROFIL=otomatik" ]; then
  sed -i '' "s/^PROFIL=.*/$OLD_PROFIL/" "$USER_CONF"
fi

# Önceki sürümden kalmış Roblox açılış ajanı varsa kaldır
launchctl bootout "gui/$(id -u)/com.goodbyedpi.roblox" >/dev/null 2>&1
rm -f "$HOME/Library/LaunchAgents/com.goodbyedpi.roblox.plist"

# --- Sistem tarafı (root) ---
echo
echo "Mac parolan istenecek (yazarken görünmez):"
sudo -v || { echo "Parola alınamadı."; pause_exit 1; }

echo "Şifreli DNS (dnscrypt-proxy) başlatılıyor..."
# Yalnızca IPv4 adres versin: aktarıcı IPv4 trafiğini yakalıyor, IPv6 ile atlanmasın
DNSCRYPT_CONF="$(brew --prefix)/etc/dnscrypt-proxy.toml"
if [ -f "$DNSCRYPT_CONF" ] && grep -qE '^block_ipv6 *= *false' "$DNSCRYPT_CONF"; then
  sed -i '' -E 's/^block_ipv6 *= *false/block_ipv6 = true/' "$DNSCRYPT_CONF" 2>/dev/null \
    || sudo sed -i '' -E 's/^block_ipv6 *= *false/block_ipv6 = true/' "$DNSCRYPT_CONF"
fi
sudo "$BREW" services restart dnscrypt-proxy >/dev/null 2>&1 || sudo "$BREW" services start dnscrypt-proxy >/dev/null 2>&1
for _ in $(seq 1 30); do
  dig +short +time=2 +tries=1 A clientsettings.roblox.com @127.0.0.1 2>/dev/null | grep -Eq '^[0-9.]+$' && break
  sleep 2
done
if dig +short +time=2 +tries=1 A clientsettings.roblox.com @127.0.0.1 2>/dev/null | grep -Eq '^[0-9.]+$'; then
  echo "  şifreli DNS hazır."
else
  echo "  UYARI: şifreli DNS henüz yanıt vermiyor; servis hazır olunca kendisi devreye alacak."
fi

TMP="$(mktemp -d)"
sed "s|__USER_CONF__|$USER_CONF|g" "$SRC/com.goodbyedpi.mac.plist" > "$TMP/daemon.plist"
DAEMON_PLIST="/Library/LaunchDaemons/com.goodbyedpi.mac.plist"

# Eski servisi durdur (kapanırken DNS/proxy/pf ayarlarını kendisi geri alır)
sudo launchctl bootout system/com.goodbyedpi.mac >/dev/null 2>&1
# Eski servis kapanırken ayarları geri alıyor; tamamen bitmesini bekle (en fazla 40 sn)
for _ in $(seq 1 40); do
  sudo launchctl print system/com.goodbyedpi.mac >/dev/null 2>&1 || break
  sleep 1
done
sudo pkill -x spoofdpi >/dev/null 2>&1
sudo pkill -f roblox-relay.py >/dev/null 2>&1

sudo mkdir -p /usr/local/etc/goodbyedpi /usr/local/libexec/goodbyedpi || { echo "Klasörler oluşturulamadı."; pause_exit 1; }
# Root olarak çalışacak dosyalar root'a ait kopyalardır (kullanıcı değiştiremesin diye)
sudo install -m 755 -o root -g wheel "$SPOOFDPI" /usr/local/libexec/goodbyedpi/spoofdpi || { echo "spoofdpi kopyalanamadı."; pause_exit 1; }
sudo install -m 755 -o root -g wheel "$SRC/calistir.sh" /usr/local/libexec/goodbyedpi/calistir.sh
sudo install -m 755 -o root -g wheel "$SRC/roblox-relay.py" /usr/local/libexec/goodbyedpi/roblox-relay.py
for i in 1 2 3 4 5 6 7 8; do
  sudo install -m 644 -o root -g wheel "$SRC/profil-$i.toml" "/usr/local/etc/goodbyedpi/profil-$i.toml"
done
sudo install -m 644 -o root -g wheel "$TMP/daemon.plist" "$DAEMON_PLIST"
rm -rf "$TMP"

# Yeni servis eski günlükle karışmasın
sudo sh -c ': > /var/log/goodbyedpi.log'

echo "Servis başlatılıyor..."
STARTED=0
for _ in 1 2 3 4 5 6; do
  if sudo launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null; then STARTED=1; break; fi
  # Hâlâ kayıtlıysa yeniden başlatmak yeterli (dosyalar zaten güncellendi)
  if sudo launchctl print system/com.goodbyedpi.mac >/dev/null 2>&1; then
    if sudo launchctl kickstart -k system/com.goodbyedpi.mac 2>/dev/null; then STARTED=1; break; fi
  fi
  sleep 3
done
if [ "$STARTED" != "1" ]; then
  echo "Servis başlatılamadı. Mac'i yeniden başlatman yeterli; açılışta kendiliğinden çalışır."
  pause_exit 1
fi

# --- Sonucu bekle ve göster (en fazla ~3 dakika) ---
echo
echo "Servis bağlantı yollarını deniyor, bekle (1-3 dakika)..."
LOG=/var/log/goodbyedpi.log
for _ in $(seq 1 90); do
  sleep 2
  if grep -qE "alternatif [0-9] çalışıyor|hiçbir alternatif doğrulanamadı|sabit alternatif" "$LOG" 2>/dev/null; then break; fi
  printf "."
done
echo
echo
echo "------------------- SONUÇ -------------------"
grep -E "DNS|doğrudan|aktarıcısı [0-9] çalışıyor|yol doğrulanamadı|python|alternatif [0-9] çalışıyor|hiçbir alternatif|sabit alternatif|internet yok" "$LOG" | sed 's/^[0-9-]* [0-9:]* /  /'
echo "---------------------------------------------"
if grep -qE "doğrudan bağlanabiliyor|aktarıcısı [0-9] çalışıyor" "$LOG"; then
  echo "KURULDU. Roblox açıksa Cmd+Q ile TAMAMEN kapat, sonra yeniden aç."
else
  echo "Kuruldu ama Roblox uygulaması yolu henüz doğrulanamadı. Servis birkaç dakikada bir yeniden dener."
  echo "Bir sorun olursa Durum.command'a çift tıkla ve ekranın fotoğrafını gönder."
fi
echo
echo "Mac her açıldığında kendiliğinden başlar; pencere/simge yok."
echo "Durum: Durum.command   Kaldırma: Kaldir.command"
pause_exit 0
