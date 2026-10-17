#!/usr/bin/env python3
"""Zero the free fragments of a big-endian 4.2BSD/4.4BSD FFS (UFS1) image:
HP-UX HFS (whole disk, the old cylinder-group format) or NetBSD/hp300
(partition `a` from the disklabel, the 4.4BSD cylinder-group format).
usage: hfs_zerofree.py IMAGE [--write] [--swap]
Without --write it only checks: each cylinder group's free map against its
counts, the total against the superblock, and that no fragment of any
allocated inode (data and indirect blocks) is marked free.  --swap (with
--write) also zeroes the disklabel's swap partitions."""
import struct, sys

path = sys.argv[1]
write = '--write' in sys.argv
swap = '--swap' in sys.argv
f = open(path, 'r+b' if write else 'rb')
g = lambda b, o: struct.unpack('>i', b[o:o+4])[0]

def rd(o, n):
    f.seek(o); return f.read(n)

# a NetBSD disklabel in the first 16 sectors: the file system is partition
# `a` (fstype 7, 4.2BSD); HP-UX has none and starts at byte 0
base, swaps = 0, []
head = rd(0, 16 * 512)
for o in range(0, len(head) - 512, 4):
    if struct.unpack('>I', head[o:o+4])[0] == 0x82564557:
        lab = head[o:o+512]
        secsz, npart = struct.unpack('>I', lab[40:44])[0], struct.unpack('>H', lab[138:140])[0]
        parts = [struct.unpack('>IIIBB', lab[148+16*i:162+16*i]) for i in range(npart)]
        assert parts[0][3] == 7, 'partition a is not 4.2BSD'
        base = parts[0][1] * secsz
        swaps = [(p[1] * secsz, p[0] * secsz) for p in parts if p[3] == 1]
        print('disklabel at %d: partition a at sector %d, %d swap partition(s)' % (o, parts[0][1], len(swaps)))
        break

sb = rd(base + 8192, 2048)
cblkno, iblkno, dblkno = g(sb, 12), g(sb, 16), g(sb, 20)
cgoff, cgmask = g(sb, 24), g(sb, 28)
size, ncg, bsize, fsize, frag = g(sb, 36), g(sb, 44), g(sb, 48), g(sb, 52), g(sb, 56)
fpg, ipg, inopb, nindir = g(sb, 188), g(sb, 184), g(sb, 120), g(sb, 116)
assert g(sb, 0x55c) == 0x011954, 'superblock magic'

def cgstart(c):
    return fpg * c + cgoff * (c & ~cgmask)

free = set()
total = 0
for c in range(ncg):
    cg = rd(base + (cgstart(c) + cblkno) * fsize, bsize)
    if g(cg, 4) == 0x090255:                     # 4.4BSD: maps at offsets in the header
        mapoff = g(cg, 96)                       # cg_freeoff
    else:                                        # 4.2BSD: maps inline after it
        assert g(cg, 980) == 0x090255, 'cg %d magic' % c
        mapoff = 984
    ndblk = g(cg, 20)
    nbfree, nffree = g(cg, 28), g(cg, 36)
    bm = cg[mapoff:mapoff + (ndblk + 7) // 8]
    n = 0
    for i in range(ndblk):
        if bm[i >> 3] >> (i & 7) & 1:
            free.add(fpg * c + i); n += 1
    assert n == nbfree * frag + nffree, 'cg %d: map %d, counts %d' % (c, n, nbfree * frag + nffree)
    total += n
if sb[211] & 0x80:                               # FS_FLAGS_UPDATED: 64-bit fs_cstotal at 1008
    q = lambda o: struct.unpack('>q', sb[o:o+8])[0]
    sb_free = q(1016) * frag + q(1032)           # cs_nbfree, cs_nffree
else:
    sb_free = g(sb, 196) * frag + g(sb, 204)     # fs_old_cstotal nbfree, nffree
assert total == sb_free, 'cylinder groups %d free, superblock %d' % (total, sb_free)
print('free fragments: %d (%d KB), agree with the superblock' % (total, total * fsize // 1024))

# every allocated inode's fragments must not be free
def inode(ino):
    c = ino // ipg
    fn = cgstart(c) + iblkno + ((ino % ipg) // inopb) * frag
    b = rd(base + fn * fsize, bsize)
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
    if g(di, 104) == 0:
        continue                                   # no blocks (a short symlink keeps its target in di_db)
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
        ptrs = struct.unpack('>%di' % nindir, rd(base + bn * fsize, bsize))
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
        f.seek(base + fr * fsize); f.write(zero)
    print('zeroed %d fragments' % len(free))
    if swap:
        for off, ln in swaps:
            f.seek(off)
            for _ in range(ln // 65536): f.write(bytes(65536))
            f.write(bytes(ln % 65536))
            print('zeroed swap: %d bytes at %d' % (ln, off))
    f.flush()
else:
    print('check only (add --write to zero)')
