#!/usr/bin/env python3
"""
run-tsr-test.py - the command-line workflow: boot DOS from a floppy, load
the overlay with EZDRV.COM, and confirm that from that point on DOS (and so
FDISK) sees hard disk 80h with the full translated geometry and can reach
past the 504MB barrier.

This is the state the disk must be in *before* it is partitioned, so the
hard disk here is the overlay disk image used only as raw sectors (its
marker at LBA 2,000,000 gives GEO.COM something real to read); the overlay
is loaded from the floppy, not from the disk. A small standard-geometry
slave rides the same channel: GEO's "drives=2" proves the overlay's AH=08
reports the BIOS's drive count instead of hiding drive 81h from DOS.

W95SIM then simulates the Windows INT 2Fh start/exit broadcasts. What must
happen depends on the BIOS underneath (--trans):
  none  the true pre-LBA setup: unhooking would misaddress everything, so
        the overlay must stay hooked through every broadcast.
  lba   an LBA-assist BIOS serving the same 255x63 translation: the
        overlay must step aside on a Win95 start (1605h) and re-hook on
        the exit broadcast (1606h).

    python3 test/run-tsr-test.py [--seconds 45] [--trans none|lba]
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
FLOPPY_SRC = os.path.expanduser(
    '~/Downloads/Microsoft MS-DOS 6.22 [Spanish] (3.5)/Disk1.img')
MNT = '/tmp/ezdrv-fd'
SEC = 512

DROP = """QBASIC.EXE MSD.EXE SCANDISK.EXE SCANDISK.INI DEFRAG.EXE DEFRAG.HL_
INSTALAR.EXE LEAME.TXT RED.TXT DRVSPACE.BIN MSCDEX.EXE EMM386.EX_ EGA.CP_
EGA2.CP_ EGA3.CP_ ISO.CP_ KEYBOARD.SYS KEYBRD2.SY_ COUNTRY.SYS REPLACE.EX_
RESTORE.EX_ XCOPY.EX_ MEM.EX_ PAIS.TX_ DOSSETUP.INI SETUP.MSG NLSFUNC.EXE
KEYB.COM EXPAND.EXE ATTRIB.EXE DEFRAG.HLP PACKING.LST FORMAT.COM SYS.COM
FDISK.EXE CHKDSK.EXE EDIT.COM""".split()

CONFIG_SYS = "DOS=HIGH\r\nFILES=20\r\n"

AUTOEXEC_BAT = (
    "@ECHO OFF\r\n"
    "ECHO ===EZDRV TSR TEST=== > A:\\OUT.TXT\r\n"
    "ECHO --- loading EZDRV (no prior disk access) --- >> A:\\OUT.TXT\r\n"
    "EZDRV >> A:\\OUT.TXT\r\n"
    "ECHO --- after EZDRV --- >> A:\\OUT.TXT\r\n"
    "GEO >> A:\\OUT.TXT\r\n"
    "ECHO --- second EZDRV (should say already) --- >> A:\\OUT.TXT\r\n"
    "EZDRV >> A:\\OUT.TXT\r\n"
    "ECHO --- Windows broadcast simulation --- >> A:\\OUT.TXT\r\n"
    "W95SIM >> A:\\OUT.TXT\r\n"
    "ECHO --- GEO after the broadcasts --- >> A:\\OUT.TXT\r\n"
    "GEO >> A:\\OUT.TXT\r\n"
    "ECHO ===DONE=== >> A:\\OUT.TXT\r\n"
)


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def build_floppy(fd):
    run(['hdiutil', 'detach', MNT])
    shutil.copyfile(FLOPPY_SRC, fd)
    os.chmod(fd, 0o644)
    r = run(['hdiutil', 'attach', '-imagekey', 'diskimage-class=CRawDiskImage',
             '-mountpoint', MNT, fd])
    if r.returncode:
        sys.exit('attach floppy: ' + r.stderr)
    try:
        for name in DROP:
            p = os.path.join(MNT, name)
            if os.path.exists(p):
                os.remove(p)
        for junk in ('.fseventsd', '.Spotlight-V100', '.TemporaryItems'):
            shutil.rmtree(os.path.join(MNT, junk), ignore_errors=True)
        env = dict(os.environ, COPYFILE_DISABLE='1')
        for b in ('EZDRV.COM', 'GEO.COM', 'W95SIM.COM'):
            subprocess.run(['cp', os.path.join(BUILD, b), MNT], check=True,
                           env=env)
        for name, body in (('CONFIG.SYS', CONFIG_SYS),
                           ('AUTOEXEC.BAT', AUTOEXEC_BAT)):
            with open(os.path.join(MNT, name), 'wb') as f:
                f.write(body.encode('ascii'))
    finally:
        for _ in range(5):
            if run(['hdiutil', 'detach', MNT]).returncode == 0:
                break
            time.sleep(1)


def check(text, trans):
    """Assert the transcript against the expectations for this BIOS."""
    want = [
        'cyls=540 heads=255 spt=63 drives=2',
        'self-test read past 504MB: OK',
        'already installed',
        'W95SIM: at start:           hooked',
        'W95SIM: after Win3.1 start: hooked',
        'W95SIM: after Windows exit: hooked',
        '===DONE===',
    ]
    if trans == 'lba':
        want.append('W95SIM: unhook gate:        open')
        want.append('W95SIM: after Win95 start:  UNHOOKED')
    else:
        want.append('W95SIM: unhook gate:        closed')
        want.append('W95SIM: after Win95 start:  hooked')
    missing = [w for w in want if w not in text]
    if 'FAILED' in text:
        missing.append('(a FAILED marker appeared)')
    if missing:
        print(f'FAIL (--trans {trans}): missing from transcript:')
        for m in missing:
            print('  ', m)
        sys.exit(1)
    print(f'PASS (--trans {trans}): geometry, reads and Windows '
          f'broadcast behavior all as expected')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=int, default=45)
    ap.add_argument('--trans', choices=['none', 'lba'], default='none',
                    help='SeaBIOS geometry translation for the hard disk')
    args = ap.parse_args()

    subprocess.run([sys.executable, os.path.join(ROOT, 'tools',
                    'mkoverlaydisk.py'), DISK], check=True)
    fd = os.path.join(BUILD, 'tsrfd.img')
    build_floppy(fd)

    # a small standard-geometry slave on the same channel: the overlay must
    # keep it visible (AH=08 has to report the BIOS's drive count, not 1)
    slave = os.path.join(BUILD, 'slavedisk.img')
    with open(slave, 'wb') as f:
        f.truncate(130 * 16 * 63 * SEC)     # ~64MB, no translation needed

    cyls = os.path.getsize(DISK) // (SEC * 16 * 63)
    cmd = [
        'qemu-system-i386', '-m', '16', '-no-reboot',
        '-drive', f'file={fd},format=raw,if=floppy,index=0',
        '-drive', f'file={DISK},format=raw,if=none,id=hd0',
        '-device', f'ide-hd,drive=hd0,bus=ide.0,unit=0,'
                   f'cyls={cyls},heads=16,secs=63,bios-chs-trans={args.trans}',
        '-drive', f'file={slave},format=raw,if=none,id=hd1',
        '-device', 'ide-hd,drive=hd1,bus=ide.0,unit=1',
        '-boot', 'a', '-display', 'none',
        '-monitor', f'unix:{BUILD}/tsrmon.sock,server,nowait',
    ]
    for stale in ('tsrmon.sock',):
        try:
            os.remove(os.path.join(BUILD, stale))
        except FileNotFoundError:
            pass
    print('qemu:', ' '.join(cmd))
    p = subprocess.Popen(cmd)
    time.sleep(args.seconds - 4)
    try:
        import socket
        s = socket.socket(socket.AF_UNIX)
        s.connect(os.path.join(BUILD, 'tsrmon.sock'))
        time.sleep(0.3)
        s.recv(4096)
        s.sendall(f'screendump {BUILD}/tsr.ppm\n'.encode())
        time.sleep(1.2)
        s.sendall(b'quit\n')
        time.sleep(0.3)
    except Exception as e:
        print('monitor:', e)
    p.wait()
    ppm = os.path.join(BUILD, 'tsr.ppm')
    if os.path.exists(ppm) and shutil.which('sips'):
        run(['sips', '-s', 'format', 'png', ppm, '--out', ppm[:-4]+'.png'])

    # pull the transcript back off the floppy
    r = run(['hdiutil', 'attach', '-imagekey', 'diskimage-class=CRawDiskImage',
             '-mountpoint', MNT, fd])
    print('--- A:\\OUT.TXT ---')
    text = ''
    try:
        path = os.path.join(MNT, 'OUT.TXT')
        if os.path.exists(path):
            with open(path, 'rb') as f:
                text = f.read().decode('cp437', 'replace').replace('\r\n', '\n')
            print(text)
        else:
            print('(no transcript)')
    finally:
        for _ in range(5):
            if run(['hdiutil', 'detach', MNT]).returncode == 0:
                break
            time.sleep(1)
    check(text, args.trans)


if __name__ == '__main__':
    main()
