# Telnet client for HP-UX 9 on the HP9K385 board: refuses every option.
# Used by hpux_put.py.
# minimal telnet client: refuse every option, log in as root, run a script
import socket, sys, time
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
class T:
    def __init__(s, host):
        s.k = socket.create_connection((host, 23), timeout=60); s.buf = b''
    def _fill(s, t):
        s.k.settimeout(t)
        try: d = s.k.recv(4096)
        except socket.timeout: return False
        if not d: raise EOFError
        out = bytearray(); i = 0
        while i < len(d):
            c = d[i]
            if c == IAC and i + 1 < len(d):
                cmd = d[i+1]
                if cmd in (DO, DONT, WILL, WONT) and i + 2 < len(d):
                    opt = d[i+2]
                    if cmd == DO: s.k.send(bytes([IAC, WONT, opt]))
                    elif cmd == WILL: s.k.send(bytes([IAC, DONT, opt]))
                    i += 3; continue
                i += 2; continue
            out.append(c); i += 1
        s.buf += bytes(out); return True
    def until(s, pat, t=60):
        end = time.time() + t
        while pat.encode() not in s.buf:
            if time.time() > end: raise TimeoutError(repr(s.buf[-200:]))
            s._fill(1)
        i = s.buf.index(pat.encode()) + len(pat); r = s.buf[:i]; s.buf = s.buf[i:]; return r.decode('latin1')
    def send(s, txt): s.k.sendall(txt.replace('\n', '\r\n').encode('latin1'))
if __name__ == '__main__':
    t = T(sys.argv[1])
    print(t.until('login:', 90))
    t.send('root\n')
    r = t.until(':', 30); print(r)
    if 'assword' in r: t.send('\n')
    print(t.until('#', 60))
    t.send('uname -a; echo DONE\n'); print(t.until('DONE', 30))
