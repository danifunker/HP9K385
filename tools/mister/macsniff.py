# macsniff.py SECONDS: run on the MiSTer; prints every frame to or from the
# 98643A MAC 08:00:09:38:50:01 (ARP, IP, other types).
import socket, time, sys
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.settimeout(1); end = time.time() + float(sys.argv[1]); mac = bytes.fromhex('080009385001')
while time.time() < end:
    try: f, a = s.recvfrom(2048)
    except socket.timeout: continue
    if f[6:12] != mac and f[0:6] != mac: continue
    t = f[12:14].hex()
    if t == '0806': info = 'ARP op %d who-has %s tell %s' % (f[21], socket.inet_ntoa(f[38:42]), socket.inet_ntoa(f[28:32]))
    elif t == '0800': info = 'IP %s -> %s proto %d' % (socket.inet_ntoa(f[26:30]), socket.inet_ntoa(f[30:34]), f[23])
    else: info = 'type ' + t
    print('%.1f %s -> %s %s' % (time.time() % 1000, f[6:12].hex(':'), f[0:6].hex(':'), info), flush=True)
