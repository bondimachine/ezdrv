#!/usr/bin/env python3
"""
run-fdisk-e2e.py - the full on-machine bring-up of a blank >504MB disk
using the EZDRV overlay and stock MS-DOS 6.22 tools, exactly as a user
would do it from a boot floppy:

  phase 1   boot A:  ->  EZDRV (hook)  ->  FDISK  (create 2GB primary)
  phase 1b  boot A:  ->  EZDRV /W      (stamp MBR + body onto the disk)
  phase 2   boot C:  ->  MBR installs hook, C: unformatted -> falls back
            to A: WITH the hook live  ->  FORMAT C: /S  ->  DIR C:
  phase 3   boot C:  (no floppy)  ->  MS-DOS boots from the hard disk
  host      mount the image on macOS and verify the FAT16 volume

FDISK is menu-driven, so phase 1 sends it keystrokes through the QEMU
monitor, advancing whenever the screen stops changing (FDISK's integrity
scan repaints a percentage, so a stable screen means the next prompt).

    python3 test/run-fdisk-e2e.py [--phase all|1|1b|2|3|host]
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
DISK = os.path.join(BUILD, 'e2edisk.img')
MON = os.path.join(BUILD, 'e2emon.sock')
FLOPPY_SRC = os.path.expanduser(
    '~/Downloads/Microsoft MS-DOS 6.22 [Spanish] (3.5)/Disk1.img')
MNT = '/tmp/ezdrv-e2e'
SEC = 512
DISK_SECTORS = 540 * 255 * 63           # 4.1GB, 540 translated cylinders

# Files stripped from the retail Setup floppy to make room. FDISK and
# FORMAT stay: they are the point of the exercise.
DROP = """QBASIC.EXE MSD.EXE SCANDISK.EXE SCANDISK.INI DEFRAG.EXE DEFRAG.HL_
INSTALAR.EXE LEAME.TXT RED.TXT DRVSPACE.BIN MSCDEX.EXE EMM386.EX_ EGA.CP_
EGA2.CP_ EGA3.CP_ ISO.CP_ KEYBOARD.SYS KEYBRD2.SY_ COUNTRY.SYS REPLACE.EX_
RESTORE.EX_ XCOPY.EX_ MEM.EX_ PAIS.TX_ DOSSETUP.INI SETUP.MSG NLSFUNC.EXE
KEYB.COM EXPAND.EXE ATTRIB.EXE DEFRAG.HLP PACKING.LST SYS.COM CHKDSK.EXE
EDIT.COM DEBUG.EXE""".split()

AUTOEXEC = {
    '1': ("@ECHO OFF\r\n"
          "EZDRV\r\n"
          "FDISK /STATUS > A:\\ST0.TXT\r\n"
          "FDISK\r\n"),
    '1b': ("@ECHO OFF\r\n"
           "EZDRV /W > A:\\ST1B.TXT\r\n"
           "ECHO STAMPED >> A:\\ST1B.TXT\r\n"),
    '2': ("@ECHO OFF\r\n"
          "FDISK /STATUS > A:\\ST2.TXT\r\n"
          "FORMAT C: /S /V:EZDRV < A:\\S.TXT > A:\\FMT.TXT\r\n"
          "COPY A:\\CONFIG.SYS C:\\ >> A:\\FMT.TXT\r\n"
          "DIR C:\\ >> A:\\FMT.TXT\r\n"
          "ECHO EZDRVE2EDONE > C:\\DONE.TXT\r\n"
          "ECHO ===DONE=== >> A:\\FMT.TXT\r\n"),
}


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def build_floppy(fd, phase):
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
        subprocess.run(['cp', os.path.join(BUILD, 'EZDRV.COM'), MNT],
                       check=True, env=env)
        with open(os.path.join(MNT, 'AUTOEXEC.BAT'), 'wb') as f:
            f.write(AUTOEXEC[phase].encode('ascii'))
        with open(os.path.join(MNT, 'CONFIG.SYS'), 'wb') as f:
            f.write(b"FILES=20\r\n")
        if phase == '2':
            with open(os.path.join(MNT, 'S.TXT'), 'wb') as f:
                f.write(b"S\r\n\r\n")
    finally:
        for _ in range(5):
            if run(['hdiutil', 'detach', MNT]).returncode == 0:
                break
            time.sleep(1)


def read_floppy_file(fd, name):
    r = run(['hdiutil', 'attach', '-imagekey', 'diskimage-class=CRawDiskImage',
             '-mountpoint', MNT, fd])
    if r.returncode:
        return None
    try:
        p = os.path.join(MNT, name)
        if not os.path.exists(p):
            return None
        with open(p, 'rb') as f:
            return f.read().decode('cp437', 'replace').replace('\r\n', '\n')
    finally:
        for _ in range(5):
            if run(['hdiutil', 'detach', MNT]).returncode == 0:
                break
            time.sleep(1)


class Guest:
    """One QEMU run with a monitor socket for screendumps and keys."""

    def __init__(self, tag, boot, floppy=None):
        self.tag = tag
        cyls = DISK_SECTORS // (16 * 63)
        cmd = ['qemu-system-i386', '-m', '16', '-no-reboot',
               '-drive', f'file={DISK},format=raw,if=none,id=hd0',
               '-device', f'ide-hd,drive=hd0,bus=ide.0,unit=0,'
                          f'cyls={cyls},heads=16,secs=63,bios-chs-trans=none',
               '-boot', boot, '-display', 'none',
               '-monitor', f'unix:{MON},server,nowait']
        if floppy:
            cmd[4:4] = ['-drive', f'file={floppy},format=raw,if=floppy,index=0']
        try:
            os.remove(MON)
        except FileNotFoundError:
            pass
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        self.sock = None
        self.shots = 0
        for _ in range(50):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(MON)
                time.sleep(0.2)
                s.recv(4096)
                self.sock = s
                break
            except OSError:
                time.sleep(0.2)

    def cmd(self, line):
        self.sock.sendall((line + '\n').encode())
        time.sleep(0.4)
        try:
            self.sock.recv(8192)
        except OSError:
            pass

    def dump(self):
        self.shots += 1
        path = os.path.join(BUILD, f'e2e-{self.tag}-{self.shots:02d}.ppm')
        self.cmd(f'screendump {path}')
        time.sleep(0.6)
        try:
            with open(path, 'rb') as f:
                return path, f.read()
        except FileNotFoundError:
            return path, b''

    def wait_stable(self, timeout, settle=2, interval=5, label=''):
        """Wait until `settle` consecutive identical screendumps."""
        last, same = None, 0
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(interval)
            if self.proc.poll() is not None:
                print(f'  [{self.tag}] guest exited ({label})')
                return 'exited'
            _, data = self.dump()
            if data and data == last:
                same += 1
                if same >= settle:
                    print(f'  [{self.tag}] screen stable ({label})')
                    return 'stable'
            else:
                same = 0
            last = data
        print(f'  [{self.tag}] TIMEOUT waiting for stable screen ({label})')
        return 'timeout'

    def wait_disk(self, needle, timeout, label=''):
        """Wait until `needle` (bytes) appears in the hard-disk image -
        completion signals written by the guest, immune to cursor blink."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(15)
            if self.proc.poll() is not None:
                print(f'  [{self.tag}] guest exited ({label})')
                return 'exited'
            self.dump()                 # keep visibility into the guest
            with open(DISK, 'rb') as f:
                data = f.read()
            if needle in data:
                print(f'  [{self.tag}] disk marker found ({label})')
                time.sleep(10)          # let trailing writes settle
                return 'found'
        print(f'  [{self.tag}] TIMEOUT ({label})')
        return 'timeout'

    def keys(self, seq):
        for k in seq:
            self.cmd(f'sendkey {k}')
            time.sleep(0.7)

    def quit(self):
        if self.proc.poll() is None:
            try:
                self.cmd('quit')
            except Exception:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        # keep only the last screendump per phase as png
        last = os.path.join(BUILD, f'e2e-{self.tag}-{self.shots:02d}.ppm')
        if os.path.exists(last) and shutil.which('sips'):
            run(['sips', '-s', 'format', 'png', last, '--out',
                 os.path.join(BUILD, f'e2e-{self.tag}.png')])
        for n in range(1, self.shots + 1):
            p = os.path.join(BUILD, f'e2e-{self.tag}-{n:02d}.ppm')
            if os.path.exists(p):
                os.remove(p)


def phase1():
    print('== phase 1: EZDRV + FDISK on a blank disk ==')
    with open(DISK, 'wb') as f:
        f.truncate(DISK_SECTORS * SEC)
    fd = os.path.join(BUILD, 'e2efd1.img')
    build_floppy(fd, '1')
    g = Guest('p1', 'a', fd)
    g.wait_stable(90, label='DOS boot + EZDRV + FDISK menu')
    g.keys(['1', 'ret'])                        # create partition/logical
    g.wait_stable(60, label='create submenu')
    g.keys(['1', 'ret'])                        # create primary partition
    g.wait_stable(600, label='integrity scan -> max-size question')
    g.keys(['s', 'ret'])                        # yes: max size + activate
    g.wait_stable(600, label='partition created / reboot notice')
    g.dump()
    g.quit()
    st0 = read_floppy_file(fd, 'ST0.TXT')
    print('--- FDISK /STATUS (hook live, before partitioning) ---')
    print(st0 or '(missing)')


def phase1b():
    print('== phase 1b: EZDRV /W stamps the overlay onto the disk ==')
    fd = os.path.join(BUILD, 'e2efd1b.img')
    build_floppy(fd, '1b')
    g = Guest('p1b', 'a', fd)
    g.wait_disk(b'EZDRV: C: not bootable', 180, label='EZDRV /W stamps MBR')
    g.quit()
    print(read_floppy_file(fd, 'ST1B.TXT') or '(missing)')
    with open(DISK, 'rb') as f:
        mbr = f.read(SEC)
    print(f'MBR after /W: sig={mbr[510:512].hex()} '
          f'code starts {mbr[:4].hex(" ")} '
          f'p1 type=0x{mbr[0x1BE+4]:02x} '
          f'start={int.from_bytes(mbr[0x1BE+8:0x1BE+12], "little")} '
          f'count={int.from_bytes(mbr[0x1BE+12:0x1BE+16], "little")}')


def phase2():
    print('== phase 2: boot C: -> hook -> fallback to A: -> FORMAT C: /S ==')
    fd = os.path.join(BUILD, 'e2efd2.img')
    build_floppy(fd, '2')
    g = Guest('p2', 'c', fd)
    g.wait_disk(b'EZDRVE2EDONE', 2400, label='FORMAT C: /S + DIR + marker')
    g.dump()
    g.quit()
    print('--- FDISK /STATUS (hook from the MBR, no TSR loaded) ---')
    print(read_floppy_file(fd, 'ST2.TXT') or '(missing)')
    print('--- FORMAT / COPY / DIR transcript ---')
    print(read_floppy_file(fd, 'FMT.TXT') or '(missing)')


def phase3():
    print('== phase 3: boot MS-DOS from the hard disk (no floppy) ==')
    g = Guest('p3', 'c')
    g.wait_stable(120, label='DOS boot from C:')
    g.keys(['ret'])                             # accept date
    time.sleep(2)
    g.keys(['ret'])                             # accept time
    time.sleep(3)
    g.dump()
    g.quit()
    print('screendump: build/e2e-p3.png')


def host_check():
    print('== host: mount the finished disk on macOS ==')
    r = run(['hdiutil', 'attach', '-imagekey', 'diskimage-class=CRawDiskImage',
             '-nomount', DISK])
    print(r.stdout.strip())
    dev = None
    for line in r.stdout.splitlines():
        if 'FDisk_partition_scheme' in line:
            dev = line.split()[0]
    if not dev:
        print('no partition scheme found')
        return
    os.makedirs(MNT + '-hd', exist_ok=True)
    m = run(['mount_msdos', '-o', 'rdonly', dev + 's1', MNT + '-hd'])
    if m.returncode:
        print('mount failed:', m.stderr.strip())
    else:
        ls = run(['ls', '-la', MNT + '-hd'])
        print(ls.stdout)
        du = run(['df', '-h', MNT + '-hd'])
        print(du.stdout.splitlines()[-1])
        run(['umount', MNT + '-hd'])
    run(['hdiutil', 'detach', dev])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--phase', default='all',
                    choices=['all', '1', '1b', '2', '3', 'host'])
    args = ap.parse_args()
    steps = {'1': phase1, '1b': phase1b, '2': phase2, '3': phase3,
             'host': host_check}
    if args.phase == 'all':
        for fn in (phase1, phase1b, phase2, phase3, host_check):
            fn()
    else:
        steps[args.phase]()


if __name__ == '__main__':
    main()
