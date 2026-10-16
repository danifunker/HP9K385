#!/usr/bin/env python3
"""Zero the free fragments of an HP-UX HFS (4.2BSD FFS, big-endian) image.
usage: hfs_zerofree.py IMAGE [--write]
Without --write it only checks: each cylinder group's free map against its
counts, the total against the superblock, and that no fragment of any
allocated inode (data and indirect blocks) is marked free."""
import struct, sys

path = sys.argv[1]
write = '--write' in sys.argv
f = open(path, 'r+b' if write else 'rb')
f.seek(8192); sb = f.read(2048)
g = lambda b, o: struct.unpack('>i', b[o:o+4])[0]
cblkno, iblkno, dblkno = g(sb, 12), g(sb, 16), g(sb, 20)
cgoff, cgmask = g(sb, 24), g(sb, 28)
size, ncg, bsize, fsize, frag = g(sb, 36), g(sb, 44), g(sb, 48), g(sb, 52), g(sb, 56)
fpg, ipg, inopb, nindir = g(sb, 188), g(sb, 184), g(sb, 120), g(sb, 116)
assert g(sb, 0x55c) == 0x011954

def rd(o, n):
    f.seek(o); return f.read(n)

def cgstart(c):
    return fpg * c + cgoff * (c & ~cgmask)

free = set()
total = 0
for c in range(ncg):
    cg = rd((cgstart(c) + cblkno) * fsize, bsize)
    assert g(cg, 980) == 0x090255, 'cg %d magic' % c
    ndblk = g(cg, 20)
    nbfree, nffree = g(cg, 28), g(cg, 36)
    bm = cg[984:984 + (ndblk + 7) // 8]
    n = 0
    for i in range(ndblk):
        if bm[i >> 3] >> (i & 7) & 1:
            free.add(fpg * c + i); n += 1
    assert n == nbfree * frag + nffree, 'cg %d: map %d, counts %d' % (c, n, nbfree * frag + nffree)
    total += n
print('free fragments: %d (%d KB)' % (total, total * fsize // 1024))

# every allocated inode's fragments must not be free
def inode(ino):
    c = ino // ipg
    fn = cgstart(c) + iblkno + ((ino % ipg) // inopb) * frag
    b = rd(fn * fsize, bsize)
    i = (ino % inopb) * 128
    return b[i:i + 128]

used = 0
for ino in range(2, ncg * ipg):
    di = inode(ino)
    mode = struct.unpack('>H', di[0:2])[0]
    if mode == 0:
        continue
    fsz = struct.unpack('>q', di[8:16])[0]
    if (mode & 0o170000) in (0o020000, 0o060000, 0o010000, 0o140000):
        continue                                   # devices, fifos, sockets
    db = struct.unpack('>12i', di[40:88]); ib = struct.unpack('>3i', di[88:100])
    nfr = (fsz + fsize - 1) // fsize
    frags = []
    for k, bn in enumerate(db):
        if bn == 0: continue
        left = nfr - k * frag
        frags.extend(range(bn, bn + max(1, min(frag, left))))
    def ind(bn, lvl):
        if bn == 0: return
        frags.extend(range(bn, bn + frag))
        ptrs = struct.unpack('>%di' % nindir, rd(bn * fsize, bsize))
        for p in ptrs:
            if p == 0: continue
            if lvl == 0: frags.extend(range(p, p + frag))
            else: ind(p, lvl - 1)
    for lvl, bn in enumerate(ib):
        ind(bn, lvl)
    bad = [x for x in frags if x in free]
    assert not bad, 'inode %d uses free fragments %s' % (ino, bad[:5])
    used += len(frags)
print('allocated inodes checked: their %d fragments are all in use' % used)

if write:
    zero = bytes(fsize)
    for fr in sorted(free):
        f.seek(fr * fsize); f.write(zero)
    f.flush()
    print('zeroed %d fragments' % len(free))
else:
    print('check only (add --write to zero)')
