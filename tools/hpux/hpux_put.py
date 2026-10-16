# hpux_put.py TOOLDIR HOST ARGS...: log in to HP-UX 9 as root over telnet
# (answering root .profile terminal questions), then for each ARG either
# run it as a shell command or, for put:LOCAL=REMOTE, copy a text file by a
# paced heredoc and verify it with sum (HP-UX cksum is a different
# algorithm).  TOOLDIR is the directory holding tn.py.
#   python3 tools/hpux/hpux_put.py tools/hpux 192.168.99.52 "uname -a" put:a.c=/tmp/a.c
import sys, time, re, subprocess
sys.path.insert(0, sys.argv[1])
from tn import T
host = sys.argv[2]
t = T(host)
t.until('login:', 120); t.send('root\n')
end = time.time() + 120
while True:
    t._fill(1)
    b = t.buf.decode('latin1')
    if 'assword' in b: t.buf = b''; t.send('\n')
    elif '[y/n]' in b: t.buf = b''; t.send('n\n')
    elif 'TERM' in b and '(' in b: t.buf = b''; t.send('\n')
    elif 'default' in b and b.rstrip().endswith(':'): t.buf = b''; t.send('\n')
    elif b.rstrip().endswith('#'): break
    if time.time() > end: raise SystemExit('login stuck: ' + b[-200:])
t.buf = b''
def run(cmd, tmo=120):
    t.send(cmd + '; echo @@DONE@@\n')
    t.until('@@DONE@@', 10)            # the echo of the command line
    return t.until('@@DONE@@', tmo).replace('@@DONE@@', '').strip()
def put(local, remote):
    data = open(local).read()
    t.send("cat > %s <<'XEOF'\n" % remote)
    time.sleep(0.3)
    for line in data.rstrip('\n').split('\n') + ['XEOF']:
        t.send(line + '\n'); time.sleep(0.06)
        t._fill(0.01)
    time.sleep(2); t._fill(2); t.buf = b''
    rc = run('sum %s' % remote).split()
    lc = subprocess.run(['sum', '-s', local], capture_output=True, text=True).stdout.split()
    print('%s: remote %s %s, local %s %s' % (remote, rc[0], rc[1], lc[0], lc[1]))
    return rc[:2] == lc[:2]
for a in sys.argv[3:]:
    if a.startswith('put:'):
        l, r = a[4:].split('=')
        if not put(l, r): raise SystemExit('checksum mismatch')
    else:
        print('$ ' + a); print(run(a, 3000))
