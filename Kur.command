#!/bin/bash
# GoodbyeDPI-Mac KURULUM: Mac açılışında arka planda otomatik çalışır.
# Çalışan alternatifi (8 tane) kendisi bulur. Çift tıkla çalıştır; bir kez yapmak yeterli.

cd "$(dirname "$0")" || exit 1
SRC="$(pwd)/dosyalar"

pause_exit() { echo; read -r -p "Çıkmak için Enter'a bas..." _; exit "${1:-0}"; }

echo "=============================================="
echo "   GoodbyeDPI-Mac KURULUM"
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

# --- Paketler ---
if ! brew list libpcap >/dev/null 2>&1; then
  echo "libpcap kuruluyor..."
  brew install libpcap || { echo "libpcap kurulamadı."; pause_exit 1; }
fi
if ! command -v spoofdpi >/dev/null 2>&1; then
  echo "spoofdpi kuruluyor..."
  brew install spoofdpi || { echo "spoofdpi kurulamadı."; pause_exit 1; }
fi
SPOOFDPI="$(command -v spoofdpi)"
echo "spoofdpi: $SPOOFDPI"

# --- Kullanıcı ayar dosyası ---
USER_DIR="$HOME/Library/Application Support/GoodbyeDPI"
USER_CONF="$USER_DIR/ayarlar.conf"
mkdir -p "$USER_DIR"
if [ ! -f "$USER_CONF" ]; then
  cp "$SRC/ayarlar.conf" "$USER_CONF"
  echo "Ayar dosyası oluşturuldu: $USER_CONF"
else
  echo "Mevcut ayar dosyan korundu."
fi

# Önceki sürümden kalmış Roblox açılış ajanı varsa kaldır
launchctl bootout "gui/$(id -u)/com.goodbyedpi.roblox" >/dev/null 2>&1
rm -f "$HOME/Library/LaunchAgents/com.goodbyedpi.roblox.plist"

# --- Sistem tarafı (root): servis dosyaları ---
echo
echo "Arka plan servisi için Mac parolan istenecek (yazarken görünmez):"
sudo -v || { echo "Parola alınamadı."; pause_exit 1; }

TMP="$(mktemp -d)"
sed "s|__USER_CONF__|$USER_CONF|g" "$SRC/com.goodbyedpi.mac.plist" > "$TMP/daemon.plist"

DAEMON_PLIST="/Library/LaunchDaemons/com.goodbyedpi.mac.plist"

# Varsa eski servisi ve elle açılmış kopyaları durdur
sudo launchctl bootout system/com.goodbyedpi.mac >/dev/null 2>&1
sudo pkill -x spoofdpi >/dev/null 2>&1

sudo mkdir -p /usr/local/etc/goodbyedpi /usr/local/libexec/goodbyedpi || { echo "Klasörler oluşturulamadı."; pause_exit 1; }
# Root olarak çalışacak dosyalar root'a ait kopyalardır (kullanıcı yazabilir olmasın diye)
sudo install -m 755 -o root -g wheel "$SPOOFDPI" /usr/local/libexec/goodbyedpi/spoofdpi || { echo "spoofdpi kopyalanamadı."; pause_exit 1; }
sudo install -m 755 -o root -g wheel "$SRC/calistir.sh" /usr/local/libexec/goodbyedpi/calistir.sh
for i in 1 2 3 4 5 6 7 8; do
  sudo install -m 644 -o root -g wheel "$SRC/profil-$i.toml" "/usr/local/etc/goodbyedpi/profil-$i.toml"
done
sudo install -m 644 -o root -g wheel "$TMP/daemon.plist" "$DAEMON_PLIST"
rm -rf "$TMP"

echo "Servis başlatılıyor..."
sudo launchctl bootstrap system "$DAEMON_PLIST" || { echo "Servis başlatılamadı. Günlük: /var/log/goodbyedpi.log"; pause_exit 1; }

echo
echo "KURULDU. Servis arka planda alternatifleri denemeye başladı (bir dakika kadar sürebilir)."
echo "Artık Mac her açıldığında kendiliğinden başlar; pencere/simge yok."
echo
echo "Hangi alternatifin çalıştığını görmek için:  tail -f /var/log/goodbyedpi.log"
echo "Ayarlar : $USER_CONF  (değiştirince Yeniden-Baslat.command)"
echo "Kaldırma: Kaldir.command"
pause_exit 0
