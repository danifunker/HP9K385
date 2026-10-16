# dhcpsniff.py SECONDS: run on the MiSTer (root, python3); prints DHCP
# packets seen on its interfaces (type, xid, chaddr, yiaddr, flags).
import socket, struct, time, sys
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.settimeout(1); end = time.time() + float(sys.argv[1])
types = {1:'DISCOVER',2:'OFFER',3:'REQUEST',5:'ACK',6:'NAK',4:'DECLINE',7:'RELEASE',8:'INFORM'}
while time.time() < end:
    try: f, a = s.recvfrom(2048)
    except socket.timeout: continue
    if len(f) < 42 or f[12:14] != b'\x08\x00' or f[23] != 17: continue
    hl = (f[14] & 15) * 4; u = 14 + hl
    sp, dp = struct.unpack('>HH', f[u:u+4])
    if not ({sp, dp} & {67, 68}): continue
    d = f[u+8:]; t = '?'
    if len(d) > 240 and d[236:240] == b'\x63\x82\x53\x63':
        o = 240
        while o < len(d) and d[o] != 255:
            if d[o] == 0: o += 1; continue
            if d[o] == 53: t = types.get(d[o+2], d[o+2])
            o += 2 + d[o+1]
    print('%.1f %s %s -> %s %s:%d -> %s:%d %s xid=%s ch=%s yi=%s flags=%04x' % (
        time.time() % 1000, a[0], f[6:12].hex(':'), f[0:6].hex(':'),
        socket.inet_ntoa(f[26:30]), sp, socket.inet_ntoa(f[30:34]), dp, t,
        d[4:8].hex(), d[28:34].hex(':'), socket.inet_ntoa(d[16:20]), struct.unpack('>H', d[10:12])[0]), flush=True)
