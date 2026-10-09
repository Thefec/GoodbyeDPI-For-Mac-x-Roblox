#!/bin/bash
# GoodbyeDPI-Mac KALDIR: arka plan servisini ve sistem proxy ayarını tamamen kaldırır.

echo "GoodbyeDPI-Mac kaldırılıyor..."
echo "Mac parolan istenecek (yazarken görünmez):"
sudo -v || { echo "Parola alınamadı."; exit 1; }

# Servis
sudo launchctl bootout system/com.goodbyedpi.mac >/dev/null 2>&1
sudo pkill -x spoofdpi >/dev/null 2>&1
sudo rm -f /Library/LaunchDaemons/com.goodbyedpi.mac.plist
sudo rm -rf /usr/local/etc/goodbyedpi /usr/local/libexec/goodbyedpi
sudo rm -f /var/log/goodbyedpi.log

# Sistem proxy'si (yalnızca 127.0.0.1'e işaret edenler)
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
  for kind in webproxy securewebproxy; do
    server="$(networksetup -get${kind} "$svc" 2>/dev/null | awk -F': ' '/^Server/{print $2}')"
    if [ "$server" = "127.0.0.1" ]; then
      sudo networksetup -set${kind}state "$svc" off >/dev/null 2>&1
      echo "  '$svc' için proxy kapatıldı."
    fi
  done
done

# Önceki sürümden kalmış Roblox ajanı (varsa) ve kullanıcı dosyaları
launchctl bootout "gui/$(id -u)/com.goodbyedpi.roblox" >/dev/null 2>&1
rm -f "$HOME/Library/LaunchAgents/com.goodbyedpi.roblox.plist"
rm -rf "$HOME/Library/Application Support/GoodbyeDPI"

echo
echo "Kaldırıldı. (Homebrew'daki spoofdpi paketine dokunulmadı; istersen: brew uninstall spoofdpi)"
echo
read -r -p "Çıkmak için Enter'a bas..." _
