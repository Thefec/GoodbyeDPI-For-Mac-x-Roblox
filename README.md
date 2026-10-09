# Goodbye DPI For Mac X Roblox

macOS'ta DPI (derin paket denetimi) tabanlı erişim engellerini aşmak için, [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI)'dan esinlenen bir araç.
Mac açıldığında **arka planda otomatik** çalışır (pencere, Dock simgesi, menü çubuğu simgesi yok) ve
**Roblox'a bağlanan alternatifi kendisi bulur**.

> GoodbyeDPI yalnızca Windows'ta çalışır (WinDivert sürücüsüne bağlı), bu yüzden Mac'e doğrudan taşınamaz.
> Bu proje aynı işi yapan [SpoofDPI](https://github.com/xvzc/SpoofDPI)'yi kurar, yapılandırır ve yönetir.

## Özellikler

- **Açılışta otomatik başlar**, arka plan servisi olarak (launchd). Terminal'i açık tutmak gerekmez.
- **8 alternatif** (GoodbyeDPI'daki "alternatif" yöntemler gibi): farklı DNS-over-HTTPS sağlayıcıları ve paket parçalama yöntemleri.
- **Otomatik seçim**: alternatifleri tek tek dener, Roblox'a bağlananı bulunca orada kalır.
- **Kendini onarır**: bağlantı sonradan koparsa diğer alternatifleri yeniden dener.
- **Güvenli kapanış**: servis durunca sistem proxy ayarı kendiliğinden geri alınır; kendi proxy'ni kullanan ağ servislerine dokunmaz.
- Tek tıkla kur / kaldır / yeniden başlat.

## Nasıl çalışır

Servis her başlangıçta:

1. Alternatifleri sırayla başlatır (önce en son çalışanı, sonra 1'den 8'e).
2. Her birinde Roblox'a (`www.roblox.com`, `apis.roblox.com`) bağlanmayı dener.
3. Bağlanan **ilk** alternatifi bulunca sistem proxy'sini ona yönlendirir ve orada kalır.
4. Çalışırken 30 saniyede bir kontrol eder. Bağlantı koparsa kopan alternatifi en sona atıp diğerlerini yeniden dener.

Doğrudan internet yoksa (Wi-Fi bağlı değilse) alternatifleri boşuna döndürmez, internet gelene kadar bekler.
Hiçbir alternatif doğrulanamazsa (ör. Roblox'un kendisi arızalıysa) 1. alternatifle çalışmaya devam eder ve 5 dakika sonra yeniden tarar. (Tarama sırasında proxy kısa süre kapalı kalır, bu yüzden sık tekrarlanmaz.)

| # | DNS-over-HTTPS | Parçalama |
|---|---|---|
| 1 | Cloudflare | SNI'dan böl |
| 2 | Google | SNI'dan böl |
| 3 | Quad9 | ilk bayttan böl |
| 4 | Cloudflare | 35 baytlık parçalar |
| 5 | Google | rastgele böl + sırayı boz |
| 6 | Cloudflare | 1 baytlık parçalar |
| 7 | Quad9 | 1 bayt + sırayı boz + 3 sahte paket |
| 8 | Google | 1 bayt + sırayı boz + 5 sahte paket |

Profiller [`dosyalar/profil-*.toml`](dosyalar) içindedir; seçenekler için [SpoofDPI belgeleri](https://spoofdpi.dev/user-guide/https/).

## Gereksinimler

- macOS
- [Homebrew](https://brew.sh) (`libpcap` ve `spoofdpi` kurulumu için)
- Yönetici parolası (kurulumda bir kez sorulur)

## Kurulum

**Git ile (önerilen):**

```bash
git clone https://github.com/KULLANICI_ADIN/GoodbyeDPI-For-Mac-x-Roblox.git
cd GoodbyeDPI-For-Mac-x-Roblox
./Kur.command
```

**ZIP ile:** Dosyaları aç, Terminal'de klasöre girip bir kez şunu çalıştır (macOS indirilen dosyaları engeller), sonra `Kur.command` dosyasına çift tıkla:

```bash
chmod +x *.command dosyalar/*.sh
xattr -dr com.apple.quarantine .
```

Kurulum `libpcap` ve `spoofdpi`'yi kurar, servisi sisteme ekler ve başlatır. Alternatifleri denemesi bir dakika kadar sürebilir.
Sonraki her Mac açılışında kendiliğinden başlar.

Hangi alternatifin seçildiğini görmek için:

```bash
tail -f /var/log/goodbyedpi.log
```

## Ayarlar

`~/Library/Application Support/GoodbyeDPI/ayarlar.conf` dosyasını bir metin düzenleyiciyle aç:

| Ayar | Değerler | Açıklama |
|---|---|---|
| `PROFIL` | `otomatik` / `1`-`8` | `otomatik` önerilen. Rakam yazarsan yalnızca o alternatif kullanılır, denenmez |
| `MOD` | `http` / `tun` | `http` önerilen (sistem proxy'si). Roblox oyunu bağlanmazsa `tun` dene (deneysel, UDP dahil tüm trafiği kapsar) |

Değiştirdikten sonra `./Yeniden-Baslat.command` çalıştır.

## Kaldırma

`./Kaldir.command` servisi ve sistem proxy ayarını tamamen kaldırır. İnternet bozulursa da bunu çalıştır.
(Homebrew'daki `spoofdpi` paketine dokunmaz; istersen `brew uninstall spoofdpi`.)

## Sorun giderme

- **Çalışıyor mu?** `tail -f /var/log/goodbyedpi.log`. Hangi alternatifin denendiğini ve seçildiğini gösterir.
- **Site açılıyor, oyun bağlanmıyor:** Doğrulama yalnızca Roblox'un web/API adreslerine HTTPS ile ulaşılıp ulaşılamadığına bakar. Oyun trafiği (UDP) `http` modunda proxy'den geçmez. `MOD=tun` yap.
- **Hiçbir alternatif çalışmıyor:** Tarayıcında "Güvenli DNS" / DNS-over-HTTPS açıksa kapat ya da sistem ayarını kullanmasını seç. Sonra servisi yeniden başlat.
- **Servis hiç başlamıyor:** `sudo launchctl print system/com.goodbyedpi.mac` çıktısına ve günlük dosyasına bak.
- **`spoofdpi`'yi güncelledin:** `./Kur.command`'ı yeniden çalıştır (servis kendi kopyasını kullanır).

## Güvenlik notları

- Servis root olarak çalışır; bu yüzden çalıştırılan her dosya (`calistir.sh`, `spoofdpi`, profiller) root'a ait kopyalardır (`/usr/local/libexec/goodbyedpi`, `/usr/local/etc/goodbyedpi`), kullanıcı tarafından değiştirilemez.
- Kullanıcının `ayarlar.conf` dosyası root tarafından **çalıştırılmaz**; yalnızca izin verilen değerler (`otomatik`, `1`-`8`, `http`, `tun`) kalıp eşleştirmesiyle okunur.
- Sistem proxy ayarı yalnızca `127.0.0.1`'e işaret ediyorsa geri alınır.

## Durum ve sınırlar

- Otomatik seçim mantığı sahte araçlarla test edilir (`test/test-calistir.sh`). **Gerçek bir Mac'te uçtan uca denenmesi sürüyor**; sorun görürsen günlük satırlarıyla issue aç.
- Hangi alternatifin çalıştığı internet sağlayıcına göre değişir; bu yüzden otomatik seçim var.
- `http` modu sistem proxy'sini kullanır. Proxy'yi yok sayan uygulamalarda ve UDP trafiğinde etkisi olmayabilir.

## Test

```bash
bash test/test-calistir.sh
```

macOS gerektirmez (Linux/macOS). `spoofdpi`, `curl`, `nc` ve `networksetup`'ın sahtelerini kullanarak servisin davranışını kontrol eder:
alternatif sırası, proxy'nin yalnızca çalışan bulununca açılması, kopma sonrası geçiş, internet yokken bekleme, sabit alternatif, tun modu.

## Krediler

- [SpoofDPI](https://github.com/xvzc/SpoofDPI) (xvzc, Apache-2.0): asıl DPI aşma işini yapan araç. Bu repo onu içermez, Homebrew'dan kurar.
- [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI) (ValdikSS) ve [GoodbyeDPI-Turkey](https://github.com/cagritaskn/GoodbyeDPI-Turkey) (cagritaskn): "alternatif yöntem" fikri için ilham.

Bu proje Roblox Corporation, SpoofDPI veya GoodbyeDPI ile bağlantılı ya da onlar tarafından onaylanmış değildir.

## Sorumluluk

Bu araç, erişim engellerini aşan ağ ayarlarını değiştirir. Kullanımından doğan her şey kendi sorumluluğundadır.
Bulunduğun ülkedeki yasalara ve kullandığın servislerin şartlarına uy.

## Lisans

[MIT](LICENSE)

---

## English summary

**Goodbye DPI For Mac X Roblox** is a macOS background service inspired by GoodbyeDPI (which is Windows-only). It installs and manages
[SpoofDPI](https://github.com/xvzc/SpoofDPI), starts at boot with no visible window, and **automatically tries 8 alternative
configurations until one can reach Roblox**, then keeps monitoring and re-scans if the connection drops.

Install: `git clone` this repo, run `./Kur.command` (needs Homebrew and an admin password). Uninstall: `./Kaldir.command`.
Settings live in `~/Library/Application Support/GoodbyeDPI/ayarlar.conf` (`PROFIL=otomatik|1-8`, `MOD=http|tun`). Logs: `/var/log/goodbyedpi.log`.
Not yet verified end-to-end on a real Mac; the selection logic is covered by `test/test-calistir.sh`. Use at your own risk and follow local laws.
