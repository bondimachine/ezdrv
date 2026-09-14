NASM  = nasm
BUILD = build

# Default build needs an 80186 or later (REP INSW/OUTSW), which every
# machine that can hold a >504MB IDE disk has. Use CPU=8086 for an
# XT-class build that moves the data port a word at a time instead.
NASMFLAGS =
ifeq ($(CPU),8086)
NASMFLAGS += -dCPU8086
endif

all: $(BUILD)/EZDRV.COM $(BUILD)/GEO.COM $(BUILD)/W95SIM.COM

$(BUILD):
	mkdir -p $(BUILD)

# The resident overlay body: INT 13h handler + ATA layer.
$(BUILD)/OVERLAY.BIN: src/overlay.asm src/ata.asm src/structs.inc | $(BUILD)
	$(NASM) -f bin -i src/ $(NASMFLAGS) src/overlay.asm -o $@

# The MBR boot code: loads the body from the track-0 gap, hooks INT 13h,
# chains to the active partition (or to the floppy, hook live).
$(BUILD)/MBR.BIN: src/mbr.asm $(BUILD)/OVERLAY.BIN | $(BUILD)
	$(NASM) -f bin \
	  -dBODY_SECS=$$(( ( $$(wc -c < $(BUILD)/OVERLAY.BIN) + 511) / 512 )) \
	  -dRESERVE_KB=$$(( ( $$(wc -c < $(BUILD)/OVERLAY.BIN) + 2047) / 1024 )) \
	  src/mbr.asm -o $@

# EZDRV.COM: run the overlay from the DOS command line, or /W it to disk.
$(BUILD)/EZDRV.COM: $(BUILD)/MBR.BIN $(BUILD)/OVERLAY.BIN src/loader.asm | $(BUILD)
	$(NASM) -f bin -i $(BUILD)/ src/loader.asm -o $@

# GEO.COM: diagnostic - report disk 80h geometry and reach as DOS sees it.
$(BUILD)/GEO.COM: src/geo.asm | $(BUILD)
	$(NASM) -f bin src/geo.asm -o $@

# W95SIM.COM: simulate the Windows INT 2Fh start/exit broadcasts and
# report whether the overlay stays hooked or steps aside.
$(BUILD)/W95SIM.COM: src/w95sim.asm | $(BUILD)
	$(NASM) -f bin src/w95sim.asm -o $@

# A boot sector that exercises the hooked INT 13h past the barrier.
$(BUILD)/TESTVBR.BIN: src/testvbr.asm | $(BUILD)
	$(NASM) -f bin -dMARKER_LBA=2000000 src/testvbr.asm -o $@

# Boot a pre-stamped overlay disk in QEMU and check it reaches past 504MB.
test: all $(BUILD)/TESTVBR.BIN
	python3 tools/mkoverlaydisk.py $(BUILD)/ovldisk.img
	python3 test/run-overlay-boot.py

# Load EZDRV.COM as a TSR under MS-DOS and check geometry + reads, plus
# the Windows broadcast behavior: on the old BIOS (trans=none) the hook
# must survive a simulated Windows 95 start; on an LBA-assist BIOS
# (trans=lba) it must step aside and come back on exit.
tsr-test: all $(BUILD)/TESTVBR.BIN
	python3 tools/mkoverlaydisk.py $(BUILD)/ovldisk.img
	python3 test/run-tsr-test.py --trans none
	python3 test/run-tsr-test.py --trans lba

# The full bring-up: blank disk -> EZDRV + FDISK -> /W -> FORMAT -> boot C:.
e2e: all
	python3 test/run-fdisk-e2e.py

clean:
	rm -rf $(BUILD)

.PHONY: all test tsr-test e2e clean
