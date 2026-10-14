#!/usr/bin/env python3
"""HP 9000/300/400 physical address names used to annotate 68k listings.

Sources: docs/reference/mame-hp380.md, docs/PLAN_385.md section 1, and (for
addresses that do not exist on a 380 but which the multi-model boot ROM still
probes) NetBSD/hp300 header knowledge.  Entries for non-380 hardware are
prefixed with "[not on 380]".
"""

FIXED = {
    0x1FFFC: 'LED latch (long write)', 0x1FFFD: 'LED latch', 0x1FFFE: 'LED latch',
    0x1FFFF: 'LED latch (diag LEDs, byte write, low lane)',
    0x420000: '8042/HIL', 0x420001: '8042 data reg', 0x420003: '8042 cmd/status reg',
    0x428000: 'HIL (8042 mirror)',
    0x470000: 'HP-IB', 0x470001: 'HP-IB ID/reset', 0x470003: 'HP-IB int/ctl (b6 IRQ, b0 DMA)',
    0x470005: 'HP-IB status (b2 KBD NMI, b6 !CIC)', 0x470007: 'HP-IB PP control',
    0x470009: 'HP-IB PP mask',
    0x478005: 'KBDNMIST (HP-IB status mirror, b2 = keyboard NMI)',
    0x500000: '98620 DMA ch0 addr', 0x500008: '98620 DMA ch1 addr',
    0x500010: '98620C ID "20C0"', 0x500014: '98620C general ctl',
    0x560000: '98550 ROM/ID base', 0x560001: '98550 ID (byte0 of card ROM) / reset',
    0x560003: '98550 interrupt reg',
    0x5F4000: 'sysreg 5F4000', 0x5F8000: 'MC6840 PTM',
    0x5121A0: '[not on 380] alpha video text RAM', 0x512704: '[not on 380] alpha video text RAM',
    0x41C0C0: '[not on 380] FRODO IISR (4xx utility chip; b0=0 service switch)',
    0x41C000: '[not on 380] FRODO (4xx utility chip)',
}

PTM = {1: 'CR1/CR3 (ctrl)', 3: 'CR2 / status', 5: 'T1 MSB', 7: 'T1 LSB',
       9: 'T2 MSB', 11: 'T2 LSB', 13: 'T3 MSB', 15: 'T3 LSB'}

CATSEYE = {
    0x40: 'VBLANK', 0x44: 'WMOVE_ACTIVE', 0x48: 'VBLANK_INTRQ', 0x4C: 'WMOVE_INTRQ',
    0x80: 'DISPLAY_PLANE_ENABLE', 0x84: 'SYNC_ENABLE', 0x88: 'WRITE_ENABLE', 0x8C: 'READ_ENABLE',
    0x90: 'FB_WRITE_ENABLE', 0x94: 'WMOVE_IE', 0x98: 'VBLANK_IE', 0x9C: 'START_WMOVE',
    0xA0: 'BLINK', 0xA8: 'ALT_FRAME', 0xEA: 'PRR', 0xEE: 'WRR', 0xF2: 'SRC_X', 0xF6: 'SRC_Y',
    0xFA: 'DST_X', 0xFE: 'DST_Y', 0x102: 'WIDTH', 0x106: 'HEIGHT',
    0x200: 'WMX', 0x204: 'RUG_REV/misc', 0x206: 'RUG_SC', 0x208: 'WMWIDTH', 0x20A: 'WMHEIGHT',
    0x20C: 'LINEPATH', 0x20E: 'LINETYPE', 0x210: 'WMSOURCEX', 0x212: 'WMSOURCEY',
    0x214: 'WMDESTX', 0x216: 'WMDESTY', 0x218: 'WMCLIPLEFT', 0x21A: 'WMCLIPRIGHT',
    0x21C: 'WMCLIPTOP', 0x21E: 'WMCLIPBOTTOM',
    0x308: 'WMWIDTH_T', 0x30A: 'WMHEIGHT_T', 0x310: 'WMSOURCEX_T', 0x312: 'WMSOURCEY_T',
    0x314: 'WMDESTX_T', 0x316: 'WMDESTY_T',
    0x500: 'FBEN1', 0x502: 'PRR1', 0x504: 'TCREN1', 0x506: 'WRR1', 0x508: 'TCWEN1',
    0x50A: 'BARC_REV1', 0x50C: 'TRR1', 0x50E: 'COLOR1', 0x510: 'VB1', 0x512: 'TRRCTL1',
    0x514: 'ACNTL1', 0x516: 'PLANEMODE1',
    0x700: 'FBEN2', 0x702: 'PRR2', 0x704: 'TCREN2', 0x706: 'WRR2', 0x708: 'TCWEN2',
    0x70A: 'BARC_REV2', 0x70C: 'TRR2', 0x70E: 'COLOR2', 0x710: 'VB2', 0x712: 'TRRCTL2',
    0x714: 'ACNTL2', 0x716: 'PLANEMODE2',
    0x800: 'STATUS',
}

NEREID = {0x003: 'BUSY', 0x0A3: 'OVERLAY_CTL', 0x0B1: 'INDEX0', 0x0B3: 'RED', 0x0B5: 'GREEN',
          0x0B7: 'BLUE', 0x0B9: 'INDEX (inverted)', 0x0BB: 'PLANE_MASK', 0x0BD: 'OVERLAY_INDEX',
          0x0BF: 'REV', 0x0F1: 'WRITE_STROBE', 0x0F9: 'READ_STROBE'}


def catseye_reg(off):
    """off = byte offset from 0x564000; MAME word register index = off / 2
    (catseye.h: PATTERNS1 0x200, FBEN1 0x280.., PATTERNS2 0x300, FBEN2 0x380.., STATUS 0x400)."""
    if off in CATSEYE:
        return 'Catseye ' + CATSEYE[off]
    if 0x400 <= off < 0x500:
        return 'Catseye PATTERNS1[%d]' % ((off - 0x400) // 2)
    if 0x600 <= off < 0x700:
        return 'Catseye PATTERNS2[%d]' % ((off - 0x600) // 2)
    if (off & ~1) in CATSEYE:
        return 'Catseye ' + CATSEYE[off & ~1] + ' (low byte)'
    return None


def hwname(a, ram_names=None):
    if a is None:
        return None
    a &= 0xFFFFFFFF
    if a in FIXED:
        return FIXED[a]
    if 0x200000 <= a < 0x400000:
        return '98550 VRAM +%x (y=%d,x=%d)' % (a - 0x200000, (a - 0x200000) >> 11, (a - 0x200000) & 0x7FF)
    if 0x400000 <= a < 0x420000:
        return '[not on 380] intio %06x' % a
    if 0x420000 <= a < 0x430000:
        return '8042 mirror (%s)' % ('data' if a & 2 == 0 else 'cmd/status')
    if 0x470000 <= a < 0x480000:
        return 'HP-IB block +%x' % (a - 0x470000)
    if 0x500000 <= a < 0x500210:
        return '98620 DMA +%x' % (a - 0x500000)
    if 0x510000 <= a < 0x520000:
        return '[not on 380] alpha video +%x' % (a - 0x510000)
    if 0x560000 <= a < 0x564000:
        if a & 1:
            return '98550 ROM byte %d (0x560000+2n+1)' % ((a - 0x560001) // 2)
        return '98550 ROM space +%x (even: reads FF)' % (a - 0x560000)
    if 0x564000 <= a < 0x566000:
        r = catseye_reg(a - 0x564000)
        return r or 'Catseye reg +%x' % (a - 0x564000)
    if 0x566000 <= a < 0x568000:
        r = NEREID.get(a - 0x566000)
        return 'Nereid ' + r if r else 'Nereid +%x' % (a - 0x566000)
    if 0x5F4000 <= a < 0x5F4010:
        return 'sysreg 0x5F4000+%x' % (a - 0x5F4000)
    if 0x5F4000 <= a < 0x5F8000:
        return 'sysreg area +%x' % (a - 0x5F4000)
    if 0x5F8000 <= a < 0x5F8010:
        return 'PTM ' + PTM.get(a - 0x5F8000, '+%x' % (a - 0x5F8000))
    if 0x600000 <= a < 0x800000:
        sc = (a - 0x600000) >> 16
        o = a & 0xFFFF
        what = {1: 'ID', 3: 'int/ctl'}.get(o, '+%x' % o)
        return 'DIO sc%d %s' % (sc, what)
    if 0x1000000 <= a < 0x20000000:
        sc = 32 + ((a - 0x1000000) // 0x400000)
        return 'DIO-II sc%d +%x' % (sc, (a - 0x1000000) % 0x400000)
    if a >= 0xFFFF0000 and ram_names:
        n = ram_names.get(a)
        if n:
            return n
    return None
