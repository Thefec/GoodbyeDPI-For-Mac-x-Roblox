#!/bin/bash
# GoodbyeDPI-Mac KALDIR: arka plan servisini, sistem proxy/DNS ayarlarını ve pf kuralını tamamen kaldırır.
# İnternet bozulursa da bunu çalıştır.

echo "GoodbyeDPI-Mac kaldırılıyor..."
echo "Mac parolan istenecek (yazarken görünmez):"
sudo -v || { echo "Parola alınamadı."; exit 1; }

# Servis (kapanırken proxy, DNS ve pf ayarlarını kendisi geri alır)
sudo launchctl bootout system/com.goodbyedpi.mac >/dev/null 2>&1
sudo pkill -x spoofdpi >/dev/null 2>&1
sudo pkill -f roblox-relay.py >/dev/null 2>&1

# Yedek temizlik: servis bir şeyi geri alamadıysa
sudo pfctl -q -a com.apple/goodbyedpi -F all >/dev/null 2>&1
if [ -s /usr/local/etc/goodbyedpi/pf-token ]; then
  sudo pfctl -q -X "$(cat /usr/local/etc/goodbyedpi/pf-token)" >/dev/null 2>&1
fi

networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
  for kind in webproxy securewebproxy; do
    server="$(networksetup -get${kind} "$svc" 2>/dev/null | awk -F': ' '/^Server/{print $2}')"
    if [ "$server" = "127.0.0.1" ]; then
      sudo networksetup -set${kind}state "$svc" off >/dev/null 2>&1
      echo "  '$svc' için proxy kapatıldı."
    fi
  done
  dns="$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$dns" = "127.0.0.1" ]; then
    saved="$(awk -F'\t' -v s="$svc" '$1==s {print $2; exit}' /usr/local/etc/goodbyedpi/dns-yedek 2>/dev/null)"
    # shellcheck disable=SC2086
    sudo networksetup -setdnsservers "$svc" ${saved:-empty} >/dev/null 2>&1
    echo "  '$svc' için DNS eski haline döndürüldü."
  fi
done
sudo dscacheutil -flushcache >/dev/null 2>&1
sudo killall -HUP mDNSResponder >/dev/null 2>&1

# Şifreli DNS servisini durdur (paket kurulu kalır)
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$b" ]; then sudo "$b" services stop dnscrypt-proxy >/dev/null 2>&1; break; fi
done

sudo rm -f /Library/LaunchDaemons/com.goodbyedpi.mac.plist
sudo rm -rf /usr/local/etc/goodbyedpi /usr/local/libexec/goodbyedpi
sudo rm -f /var/log/goodbyedpi.log

# Önceki sürümden kalmış Roblox ajanı (varsa) ve kullanıcı dosyaları
launchctl bootout "gui/$(id -u)/com.goodbyedpi.roblox" >/dev/null 2>&1
rm -f "$HOME/Library/LaunchAgents/com.goodbyedpi.roblox.plist"
rm -rf "$HOME/Library/Application Support/GoodbyeDPI"

echo
echo "Kaldırıldı. (Homebrew paketleri kurulu kaldı; istersen: brew uninstall spoofdpi dnscrypt-proxy)"
echo
read -r -p "Çıkmak için Enter'a bas..." _
