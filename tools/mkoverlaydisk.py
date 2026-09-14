#!/usr/bin/env python3
"""
mkoverlaydisk.py - build a disk that carries the EZDRV standard-layout
overlay, for the boot-path test.

    python3 tools/mkoverlaydisk.py build/ovldisk.img

The disk is laid out in the translated 255 x 63 geometry the overlay
presents, so the whole thing fits under 1024 cylinders:

    LBA 0        MBR   : EZDRV boot code (build/MBR.BIN) + real table
    LBA 1..      gap   : overlay body (build/OVERLAY.BIN)
    LBA 63       p1    : 0x06 FAT16, active   -> boot code under test
    (p2)         p2    : 0x06 FAT16           -> a real volume for the
                                                 host-mount check
    MARKER_LBA         : an 8-byte signature the boot code reads back

For the test, p1's boot sector is build/TESTVBR.BIN (a stand-in that
drives INT 13h past the barrier), so p1 is not a mountable filesystem -
that is deliberate. p2 is a genuine FAT16 volume, present to prove the
overlay body in the gap does not disturb a normal partition parse.

Everything is deterministic.
"""

import argparse
import os
import struct

SEC = 512
DOS_DATE = (2026 - 1980) << 9 | (1 << 5) | 1   # fixed: 2026-01-01
DOS_TIME = 12 << 11                             # fixed: 12:00:00
HEADS = 255
SPT = 63
CYL = HEADS * SPT                               # 16065 sectors / cylinder
BUILD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     'build')


class Fat16Volume:
    """Minimal deterministic FAT16 volume builder."""

    def __init__(self, total_sectors, hidden, label=b'EZDRV      ',
                 bpb_heads=HEADS):
        self.bpb_heads = bpb_heads
        self.total = total_sectors
        self.hidden = hidden
        self.reserved = 1
        self.nfats = 2
        self.root_entries = 512
        self.root_secs = self.root_entries * 32 // SEC

        # Pick sectors/cluster so the cluster count lands in FAT16
        # territory (4085..65524).
        for spc in (1, 2, 4, 8, 16, 32, 64):
            fatsz = 1
            while True:
                data = self.total - self.reserved - self.nfats * fatsz \
                    - self.root_secs
                clusters = data // spc
                need = ((clusters + 2) * 2 + SEC - 1) // SEC
                if need <= fatsz:
                    break
                fatsz = need
            if clusters < 4085:
                continue
            if clusters <= 65524:
                self.spc, self.fatsz, self.clusters = spc, fatsz, clusters
                break
        else:
            raise SystemExit('volume size has no valid FAT16 layout')

        self.label = label
        self.fat = [0] * (self.clusters + 2)
        self.fat[0] = 0xFFF8
        self.fat[1] = 0xFFFF
        self.rootdir = []
        self.data = {}
        self.next_free = 2

    @property
    def data_start(self):
        return self.reserved + self.nfats * self.fatsz + self.root_secs

    def cluster_lba(self, n):
        return self.data_start + (n - 2) * self.spc

    def _chain(self, nclusters, at=None):
        start = self.next_free if at is None else at
        chain = list(range(start, start + nclusters))
        if chain[-1] >= self.clusters + 2:
            raise SystemExit('volume full')
        self.next_free = max(self.next_free, chain[-1] + 1)
        for a, b in zip(chain, chain[1:]):
            self.fat[a] = b
        self.fat[chain[-1]] = 0xFFFF
        return chain

    def _dirent(self, name83, cluster, size):
        base, _, ext = name83.partition('.')
        name11 = (base.ljust(8)[:8] + ext.ljust(3)[:3]).upper().encode()
        self.rootdir.append(struct.pack('<11sB10xHHHI', name11, 0x20,
                                        DOS_TIME, DOS_DATE, cluster, size))

    def add_file(self, name83, content, at=None):
        """Add a file. `at` forces the starting cluster, which is how the
        test parks data past sector 65535 of a volume: DOS only reaches for
        the driver's 32-bit sector field beyond that point."""
        csize = self.spc * SEC
        chain = self._chain(max(1, (len(content) + csize - 1) // csize), at)
        for i, c in enumerate(chain):
            self.data[c] = content[i*csize:(i+1)*csize].ljust(csize, b'\0')
        self._dirent(name83, chain[0], len(content))

    def add_filler(self, name83, nclusters):
        """Claim a run of clusters without writing their data, so the
        volume's free space starts near the end. Cheap on disk; the file
        reads back as zeros, which nothing in the test cares about."""
        chain = self._chain(nclusters)
        self._dirent(name83, chain[0], nclusters * self.spc * SEC)

    def vbr(self):
        bpb = struct.pack(
            '<3s8sHBHBHHBHHHII',
            b'\xEB\x3C\x90', b'MSDOS5.0',
            SEC, self.spc, self.reserved, self.nfats, self.root_entries,
            self.total if self.total < 0x10000 else 0,
            0xF8, self.fatsz, SPT, self.bpb_heads, self.hidden,
            self.total if self.total >= 0x10000 else 0)
        ext = struct.pack('<BBBI11s8s', 0x80, 0, 0x29, 0xE2D2D000,
                          self.label, b'FAT16   ')
        sec = bytearray(SEC)
        sec[:len(bpb)] = bpb
        sec[0x24:0x24+len(ext)] = ext
        sec[510:512] = b'\x55\xAA'
        return bytes(sec)

    def write_into(self, f, base):
        """Write the volume at absolute sector `base` of an open file."""
        def put(lba, blob):
            f.seek((base + lba) * SEC)
            f.write(blob)

        put(0, self.vbr())
        fat = bytearray(self.fatsz * SEC)
        for i, v in enumerate(self.fat):
            fat[i*2:i*2+2] = struct.pack('<H', v)
        for n in range(self.nfats):
            put(self.reserved + n * self.fatsz, bytes(fat))
        if self.rootdir:
            put(self.reserved + self.nfats * self.fatsz,
                b''.join(self.rootdir))
        for c, blob in self.data.items():
            put(self.cluster_lba(c), blob)


def chs(lba):
    c, r = divmod(lba, CYL)
    h, s = divmod(r, SPT)
    s += 1
    if c > 1023:
        c, h, s = 1023, 254, 63
    return bytes((h, ((c >> 2) & 0xC0) | s, c & 0xFF))


def part_entry(start, count, ptype, active=False):
    return (bytes((0x80 if active else 0,)) + chs(start) + bytes((ptype,))
            + chs(start + count - 1) + struct.pack('<II', start, count))


def load(name):
    with open(os.path.join(BUILD, name), 'rb') as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--cyls', type=int, default=540)     # ~4.1GB
    ap.add_argument('--part-cyls', type=int, default=260)  # ~2039MB each
    ap.add_argument('--marker', type=int, default=2000000)
    args = ap.parse_args()

    total = args.cyls * CYL
    # Two partitions just under the 2GB FAT16 ceiling, cylinder-aligned.
    p1_start = SPT                                        # LBA 63
    p1_end = args.part_cyls * CYL
    p2_start = p1_end
    p2_end = p2_start + args.part_cyls * CYL
    assert p2_end <= total, 'partitions exceed the disk'

    mbr_code = load('MBR.BIN')
    body = load('OVERLAY.BIN')
    testvbr = load('TESTVBR.BIN')
    assert len(mbr_code) == 446, len(mbr_code)
    assert len(testvbr) == 512, len(testvbr)
    body_secs = (len(body) + SEC - 1) // SEC
    assert 1 + body_secs <= p1_start, 'body does not fit in the track-0 gap'
    assert args.marker < total and args.marker > 1032192, 'marker placement'

    mbr = bytearray(SEC)
    mbr[0:446] = mbr_code
    mbr[0x1BE:0x1CE] = part_entry(p1_start, p1_end - p1_start, 0x06, True)
    mbr[0x1CE:0x1DE] = part_entry(p2_start, p2_end - p2_start, 0x06)
    mbr[510:512] = b'\x55\xAA'

    with open(args.out, 'wb') as f:
        f.truncate(total * SEC)                           # sparse
        f.seek(0)
        f.write(mbr)
        f.seek(1 * SEC)                                   # body at LBA 1
        f.write(body)
        f.seek(p1_start * SEC)                            # p1 boot sector
        f.write(testvbr)

        # marker sector the boot code reads back
        marker = b'OVLMARK!' + bytes((i * 3 + 1) & 0xFF for i in range(504))
        f.seek(args.marker * SEC)
        f.write(marker)

        # a real FAT16 volume on p2 (BPB in 255x63 geometry)
        v = Fat16Volume(p2_end - p2_start, p2_start, b'OVLDATA    ')
        v.add_file('HELLO.TXT', b'EZDRV data volume, standard layout.\r\n')
        v.write_into(f, p2_start)

    print(f'{args.out}: {total*SEC>>20}MB, {args.cyls}x{HEADS}x{SPT}')
    print(f'  MBR: {len(mbr_code)}B code + real table; body {body_secs} '
          f'sectors at LBA 1')
    print(f'  p1 0x06 active LBA {p1_start} ({(p1_end-p1_start)*SEC>>20}MB) '
          f'- TESTVBR boot sector')
    print(f'  p2 0x06        LBA {p2_start} ({(p2_end-p2_start)*SEC>>20}MB) '
          f'- FAT16')
    print(f'  marker at LBA {args.marker} (past the 504MB barrier)')
    print(f'  file size on disk: {os.stat(args.out).st_blocks * 512 >> 20}MB')


if __name__ == '__main__':
    main()
