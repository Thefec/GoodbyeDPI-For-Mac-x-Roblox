#!/usr/bin/env python3
# GoodbyeDPI-Mac: Roblox uygulaması için şeffaf aktarıcı.
#
# Roblox uygulaması macOS'un sistem proxy'sini kullanmıyor. Bu yüzden pf, yalnızca Roblox IP'lerine
# giden 443 trafiğini buraya (127.0.0.1:8443) yönlendirir. Aktarıcı TLS ClientHello'yu okur,
# içindeki alan adını (SNI) bulur, o adrese kendisi bağlanır ve ClientHello'yu DPI'nin
# tanıyamayacağı şekilde parçalayıp gönderir. Sonrası düz aktarımdır (şifre çözülmez).
#
# Kullanım: roblox-relay.py <strateji 1-3>
#   1 = ClientHello iki TLS kaydına bölünür (SNI'nın ortasından), ayrı TCP paketleriyle
#   2 = tek TLS kaydı, ama SNI'nın ortasından iki TCP paketine bölünür
#   3 = TLS kaydı bölünür ve her parça ayrıca iki TCP paketine bölünür
#
# Root olarak başlar, portu açtıktan sonra 'nobody' kullanıcısına düşer. pf kuralı 'nobody'nin
# trafiğini yönlendirmez; böylece aktarıcının kendi bağlantıları döngüye girmez.
# Python 3.8+ (macOS'taki /usr/bin/python3) ile uyumludur; ek paket gerekmez.

import asyncio
import os
import pwd
import socket
import sys

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("GDPI_RELAY_PORT", "8443"))
UPSTREAM_PORT = int(os.environ.get("GDPI_RELAY_UPSTREAM_PORT", "443"))
RESOLVE_OVERRIDE = os.environ.get("GDPI_RELAY_RESOLVE", "")   # yalnızca testler için
DROP_TO = os.environ.get("GDPI_RELAY_USER", "nobody")
CONNECT_TIMEOUT = 10
SPLIT_DELAY = 0.005

STRATEGY = 1


def log(msg):
    sys.stderr.write("relay: %s\n" % msg)
    sys.stderr.flush()


def find_sni(body):
    """Handshake gövdesinden (TLS kayıt başlığı hariç) SNI'yı bulur.
    Dönüş: (alan_adı, gövdedeki başlangıç, uzunluk) ya da None."""
    try:
        if len(body) < 4 or body[0] != 1:          # ClientHello değil
            return None
        p = 4 + 2 + 32                               # tip+uzunluk, sürüm, random
        sid_len = body[p]
        p += 1 + sid_len
        cs_len = int.from_bytes(body[p:p + 2], "big")
        p += 2 + cs_len
        comp_len = body[p]
        p += 1 + comp_len
        ext_total = int.from_bytes(body[p:p + 2], "big")
        p += 2
        end = min(len(body), p + ext_total)
        while p + 4 <= end:
            etype = int.from_bytes(body[p:p + 2], "big")
            elen = int.from_bytes(body[p + 2:p + 4], "big")
            data_start = p + 4
            if etype == 0 and elen >= 5:             # server_name
                q = data_start + 2                   # liste uzunluğu
                name_type = body[q]
                name_len = int.from_bytes(body[q + 1:q + 3], "big")
                if name_type == 0:
                    start = q + 3
                    name = body[start:start + name_len].decode("ascii", "strict")
                    return name, start, name_len
            p = data_start + elen
    except (IndexError, UnicodeDecodeError):
        return None
    return None


def build_chunks(header, body, sni_start, sni_len):
    """Stratejiye göre gönderilecek parçaların listesi (her biri ayrı TCP yazımı)."""
    cut = sni_start + max(1, sni_len // 2)
    rtype, ver = header[0:1], header[1:3]

    def record(payload):
        return rtype + ver + len(payload).to_bytes(2, "big") + payload

    if STRATEGY == 2:
        full = header + body
        return [full[:5 + cut], full[5 + cut:]]
    rec1, rec2 = record(body[:cut]), record(body[cut:])
    if STRATEGY == 3:
        return [rec1[:7], rec1[7:], rec2[:3], rec2[3:]]
    return [rec1, rec2]


async def resolve(host):
    if RESOLVE_OVERRIDE:
        return RESOLVE_OVERRIDE
    loop = asyncio.get_event_loop()
    infos = await loop.getaddrinfo(host, UPSTREAM_PORT, family=socket.AF_INET, type=socket.SOCK_STREAM)
    for info in infos:
        ip = info[4][0]
        if not ip.startswith("127."):
            return ip
    raise OSError("adres bulunamadı: %s" % host)


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError, asyncio.CancelledError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def handle(creader, cwriter):
    uwriter = None
    try:
        header = await asyncio.wait_for(creader.readexactly(5), CONNECT_TIMEOUT)
        if header[0] != 0x16:                        # TLS handshake değil: aktaramayız
            return
        length = int.from_bytes(header[3:5], "big")
        body = await asyncio.wait_for(creader.readexactly(length), CONNECT_TIMEOUT)
        found = find_sni(body)
        if not found:
            return
        host, sni_start, sni_len = found

        ip = await resolve(host)
        ureader, uwriter = await asyncio.wait_for(asyncio.open_connection(ip, UPSTREAM_PORT), CONNECT_TIMEOUT)
        sock = uwriter.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        for chunk in build_chunks(header, body, sni_start, sni_len):
            uwriter.write(chunk)
            await uwriter.drain()
            await asyncio.sleep(SPLIT_DELAY)

        await asyncio.gather(pipe(creader, uwriter), pipe(ureader, cwriter))
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError, OSError):
        pass
    finally:
        for w in (cwriter, uwriter):
            if w is not None:
                try:
                    w.close()
                except (OSError, RuntimeError):
                    pass


def drop_privileges():
    if os.getuid() != 0:
        return
    pw = pwd.getpwnam(DROP_TO)
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT, reuse_address=True)
    drop_privileges()
    log("dinliyor %s:%d strateji=%d" % (LISTEN_HOST, LISTEN_PORT, STRATEGY))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("1", "2", "3"):
        STRATEGY = int(sys.argv[1])
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
