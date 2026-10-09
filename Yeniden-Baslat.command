#!/bin/bash
# Ayarlar.conf'u değiştirdikten sonra arka plan servisini yeniden başlatır.

echo "Servis yeniden başlatılıyor (Mac parolan istenebilir)..."
if sudo launchctl kickstart -k system/com.goodbyedpi.mac; then
  echo "Tamam."
else
  echo "Servis bulunamadı. Önce Kur.command çalıştırıldı mı?"
fi
echo
read -r -p "Çıkmak için Enter'a bas..." _
