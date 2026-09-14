#!/usr/bin/env python3
"""
run-overlay-boot.py - boot the EZDRV overlay disk in QEMU and confirm the
overlay carries INT 13h past the 504MB barrier in the real boot path.

QEMU is given the disk with bios-chs-trans=none and its true (large)
geometry, so SeaBIOS reports the old 1024-cylinder limit: without the
overlay, cylinders past 1023 are unreachable and the extensions are
absent. The disk boots itself - MBR loads the overlay body, hooks INT 13h,
chains to p1's boot sector (TESTVBR) - which then reads a marker at LBA
2,000,000 three ways and writes a verdict the host checks.

    python3 test/run-overlay-boot.py [--seconds 30]
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
DISK = os.path.join(BUILD, 'ovldisk.img')
MARKER_LBA = 2000000
SEC = 512


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=int, default=30)
    args = ap.parse_args()

    subprocess.run([sys.executable, os.path.join(ROOT, 'tools',
                    'mkoverlaydisk.py'), DISK], check=True)

    # Physical IDE geometry is limited to 16 heads; the overlay presents the
    # translated 255x63 itself. With bios-chs-trans=none SeaBIOS still reports
    # the 1024-cylinder limit, so the 504MB barrier is genuinely present.
    cyls = os.path.getsize(DISK) // (SEC * 16 * 63)
    cmd = [
        'qemu-system-i386', '-m', '16', '-no-reboot',
        '-drive', f'file={DISK},format=raw,if=none,id=hd0',
        '-device', f'ide-hd,drive=hd0,bus=ide.0,unit=0,'
                   f'cyls={cyls},heads=16,secs=63,bios-chs-trans=none',
        '-boot', 'c', '-display', 'none', '-monitor', 'stdio',
    ]
    print('qemu:', ' '.join(cmd))
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    start = time.time()
    for at in (6, 12, 20):
        time.sleep(max(0, start + at - time.time()))
        shot = os.path.join(BUILD, f'ovl-{at}s.ppm')
        try:
            p.stdin.write(f'screendump {shot}\n')
            p.stdin.flush()
        except BrokenPipeError:
            break
    time.sleep(max(0, start + args.seconds - time.time()))
    try:
        p.stdin.write('quit\n')
        p.stdin.flush()
        out, _ = p.communicate(timeout=15)
    except (subprocess.TimeoutExpired, BrokenPipeError):
        p.kill()
        out, _ = p.communicate()

    for at in (6, 12, 20):
        ppm = os.path.join(BUILD, f'ovl-{at}s.ppm')
        if os.path.exists(ppm) and shutil.which('sips'):
            run(['sips', '-s', 'format', 'png', ppm, '--out', ppm[:-4]+'.png'])

    # The boot code wrote its verdict to MARKER_LBA+1.
    with open(DISK, 'rb') as f:
        f.seek((MARKER_LBA + 1) * SEC)
        verdict = f.read(8)
    print('--- verdict sector (written by the overlay-served boot code) ---')
    if verdict == b'OVLPASS!':
        print('PASS: overlay served AH=42, AH=02 and AH=43 past 504MB')
    elif verdict == b'OVLFAIL!':
        print('FAIL: boot code ran but a transfer did not verify')
    else:
        print(f'INCONCLUSIVE: verdict = {verdict!r} '
              '(boot code may not have reached the write)')


if __name__ == '__main__':
    main()
