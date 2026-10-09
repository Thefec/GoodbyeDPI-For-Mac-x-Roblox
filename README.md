# Goodbye DPI For Mac X Roblox

macOS'ta Roblox erişim engelini aşmak için, [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI)'dan esinlenen bir araç.
Mac açıldığında **arka planda otomatik** çalışır (pencere, Dock simgesi, menü çubuğu simgesi yok).
Hem **tarayıcıda roblox.com** hem de **Roblox uygulaması** için çalışan yolu kendisi bulur.

> GoodbyeDPI yalnızca Windows'ta çalışır (WinDivert sürücüsüne bağlı), bu yüzden Mac'e doğrudan taşınamaz.
> Bu proje aynı işi macOS'ta [SpoofDPI](https://github.com/xvzc/SpoofDPI), [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy)
> ve kendi küçük aktarıcısıyla yapar.

## Kurulum (tek komut)

Terminal'i aç, şunu yapıştır, Enter'a bas. Mac parolan istenecek:

```bash
cd ~/Downloads && rm -rf GoodbyeDPI-For-Mac-x-Roblox-main && curl -fsSL -o gdpi.zip https://github.com/Thefec/GoodbyeDPI-For-Mac-x-Roblox/archive/refs/heads/main.zip && unzip -q -o gdpi.zip && cd GoodbyeDPI-For-Mac-x-Roblox-main && bash Kur.command
```

Kurulum gerekli paketleri kurar, servisi başlatır, çalışan yolları bulmasını bekler ve **sonucu ekranda gösterir**.
Güncellemek için de aynı komutu çalıştır. Gereksinimler: macOS, [Homebrew](https://brew.sh).

## Nasıl çalışır

Engel üç parçalıdır; servis her birini ayrı çözer, her çözümü kendisi sınar ve gerekmeyeni açmaz:

| Katman | Sorun | Çözüm |
|---|---|---|
| 1. DNS | Operatör Roblox adreslerine sahte IP veriyor (engel sayfası, sahte sertifika). Normal DNS sorguları da kesiliyor. | Yerel **şifreli DNS** (dnscrypt-proxy, `127.0.0.1`). Çalışmazsa eski DNS'e döner, internet bozulmaz. |
| 2. Roblox uygulaması | Uygulama sistem proxy'sini kullanmıyor; bağlantının içindeki alan adı (SNI) DPI tarafından görülüyor. | Önce doğrudan bağlantı denenir. Olmazsa **yalnızca Roblox adreslerine** (Roblox IP blokları ve indiricinin kullandığı CDN adresleri) giden trafik `pf` ile yerel aktarıcıya yönlendirilir; aktarıcı TLS ClientHello'yu parçalar. 3 strateji sırayla denenir. |
| 3. Tarayıcı | Aynı SNI engeli | 8 SpoofDPI alternatifi sırayla denenir, Roblox'a bağlanan sistem proxy'si yapılır. |

Çalışırken 30 saniyede bir kontrol eder. Bir yol koparsa yeniden tarar. İnternet yoksa bekler.

| # | DNS-over-HTTPS | Parçalama (tarayıcı alternatifleri) |
|---|---|---|
| 1 | Cloudflare | SNI'dan böl |
| 2 | Google | SNI'dan böl |
| 3 | Quad9 | ilk bayttan böl |
| 4 | Cloudflare | 35 baytlık parçalar |
| 5 | Google | rastgele böl + sırayı boz |
| 6 | Cloudflare | 1 baytlık parçalar |
| 7 | Quad9 | 1 bayt + sırayı boz + 3 sahte paket |
| 8 | Google | 1 bayt + sırayı boz + 5 sahte paket |

## Durum ve sorun giderme

**`Durum.command`'a çift tıkla.** Servis, DNS, Roblox uygulaması ve tarayıcı yolunu ✓/✗ ile ve son olayları tek ekranda gösterir.
Sorun varsa o ekranın fotoğrafıyla issue aç.

- **İnternet bozuldu:** `Kaldir.command` her şeyi (proxy, DNS, pf) geri alır.
- **Roblox açıkken kurdun:** Roblox'u tamamen kapatıp yeniden aç.
- **"python3 yok":** Açılan pencereden Apple komut satırı araçlarını kur, sonra kurulumu yeniden çalıştır.

## Ayarlar

`~/Library/Application Support/GoodbyeDPI/ayarlar.conf`:

| Ayar | Değerler | Açıklama |
|---|---|---|
| `PROFIL` | `otomatik` / `1`-`8` | Tarayıcı alternatifi. `otomatik` önerilen |

Değiştirdikten sonra `Yeniden-Baslat.command`. (v0.1'deki `MOD=tun` kaldırıldı: SpoofDPI'nin deneysel tun modu takılıyordu.)

## Kaldırma

`Kaldir.command`: servisi, sistem proxy'sini, DNS ayarını ve pf kuralını geri alır, şifreli DNS'i durdurur.
(Homebrew paketleri kalır; istersen `brew uninstall spoofdpi dnscrypt-proxy`.)

## Güvenlik notları

- Servis root olarak çalışır; çalıştırdığı her dosya root'a ait kopyalardır (`/usr/local/libexec/goodbyedpi`, `/usr/local/etc/goodbyedpi`).
- Kullanıcının `ayarlar.conf` dosyası **çalıştırılmaz**; yalnızca izin verilen değerler okunur.
- Aktarıcı portu açtıktan sonra `nobody` kullanıcısına düşer. Şifre çözmez, sertifika kurmaz; yalnızca ilk paketi parçalar, sonrasını olduğu gibi aktarır.
- `pf` kuralı yalnızca Roblox IP bloklarına (AS22697) ve Roblox alan adlarının çözüldüğü CDN IP'lerine giden 443 trafiğini etkiler; macOS'un `com.apple/goodbyedpi` çapasına yüklenir, `/etc/pf.conf` değiştirilmez.
- DNS ve proxy ayarları yalnızca `127.0.0.1`'e işaret ediyorsa geri alınır; önceki DNS sunucuların kaydedilip geri yüklenir.

## Test

```bash
bash test/test-calistir.sh
```

macOS gerektirmez. Servisin davranışını sahte araçlarla kontrol eder (51 kontrol): alternatif sırası, kopma sonrası geçiş,
DNS'in açılıp eski haline dönmesi, şifreli DNS çökerse geri dönüş, aktarıcı stratejileri, pf kuralının kurulup kaldırılması,
internet yokken bekleme, ayar dosyasına komut enjeksiyonu.

**Durum:** Engelin üç parçası gerçek bir Mac'te (macOS 13, Türk Telekom) ayrı ayrı doğrulandı. Aktarıcı yerel TLS sunucusuyla test edildi.
Uygulama yolunun uçtan uca doğrulaması kurulumda otomatik yapılır ve sonucu ekranda gösterilir.

## Krediler

- [SpoofDPI](https://github.com/xvzc/SpoofDPI) (xvzc, Apache-2.0) ve [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) (ISC): Homebrew'dan kurulur, bu repo içermez.
- [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI) (ValdikSS) ve [GoodbyeDPI-Turkey](https://github.com/cagritaskn/GoodbyeDPI-Turkey) (cagritaskn): "alternatif yöntem" fikri.

Bu proje Roblox Corporation, SpoofDPI, dnscrypt-proxy veya GoodbyeDPI ile bağlantılı ya da onlar tarafından onaylanmış değildir.

## Sorumluluk

Bu araç, erişim engellerini aşan ağ ayarlarını değiştirir. Kullanımından doğan her şey kendi sorumluluğundadır.
Bulunduğun ülkedeki yasalara ve kullandığın servislerin şartlarına uy.

## Lisans

[MIT](LICENSE)

---

## English summary

**Goodbye DPI For Mac X Roblox** is a macOS background service (starts at boot, no visible window) that gets both the Roblox website
and the **Roblox app** past ISP DNS poisoning and SNI-based DPI. It runs three self-checking layers: a local encrypted DNS resolver
(dnscrypt-proxy; reverts to the previous DNS if it fails), a transparent relay that `pf` feeds only Roblox-bound port-443 traffic and
that fragments the TLS ClientHello (needed because the Roblox app ignores the system proxy), and 8 SpoofDPI alternatives for browsers.

Install: run the one-line command above (needs Homebrew). Status: `Durum.command`. Uninstall: `Kaldir.command`.
Logic is covered by `test/test-calistir.sh` (fake tools, no macOS needed). Use at your own risk and follow local laws.
