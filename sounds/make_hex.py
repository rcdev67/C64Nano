#!/usr/bin/env python3
"""Turn snds1541.bin into the two hex files src/misc/drive_sound.v reads.

    py -3 sounds/make_hex.py

Writes src/misc/drive_motor.hex and src/misc/drive_head.hex. Both are generated
-- edit this script, never them. Run it from the repository root.

Why 11025 Hz and five sounds: the player holds the samples in block RAM, and
this core leaves exactly four of the 46 free. 22050 Hz needs seven. 8000 Hz fits
all seven sounds including the disk-slipping loop, but at 8 kHz the averaging
filter takes the bite out of a step -- its peak drops from 26 to 13 -- and the
clack is what the whole thing exists for. So the slipping loop goes, and the
drive hums whether or not a disk is in it.

Averaged over each input window rather than picking every n-th sample: the set
has content above 5 kHz, and dropping samples folds it back down as a hiss.
"""

import io
import os
import sys

IN_HZ = 22050
OUT_HZ = 11025

# Offsets and lengths of the set, taken from fpga/1541/vhdl_source/mm_drive.vhd
# of the 1541 Ultimate firmware, where its own player is instantiated. They are
# not in that project's documentation.
PARTS = {
    "hum":      (0x0000, 4410),
    "slip":     (0x1200, 4410),
    "step_in":  (0x2400, 0x0800),
    "step_out": (0x2C00, 0x0880),
    "bang":     (0x3480, 0x0880),
}

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "snds1541.bin")
DST = os.path.normpath(os.path.join(HERE, "..", "src", "misc"))


def signed(b):
    return b - 256 if b > 127 else b


def resample(seg):
    n_out = int(len(seg) * OUT_HZ / IN_HZ)
    out = []
    for i in range(n_out):
        a = i * len(seg) / n_out
        b = (i + 1) * len(seg) / n_out
        i0 = int(a)
        i1 = min(max(i0 + 1, int(b)), len(seg))
        acc = sum(signed(seg[j]) for j in range(i0, i1))
        v = int(round(acc / (i1 - i0)))
        out.append(max(-128, min(127, v)))
    return out


def main():
    data = open(SRC, "rb").read()
    if len(data) != 46336:
        sys.exit("%s is %d bytes, expected 46336" % (SRC, len(data)))

    res = {k: resample(data[o:o + l]) for k, (o, l) in PARTS.items()}

    # One memory per channel, sounds stored back to back, so that neither
    # memory is ever read from two places at once.
    banks = {
        "drive_motor.hex": res["hum"],
        "drive_head.hex": res["step_in"] + res["step_out"] + res["bang"],
    }

    for name, vals in banks.items():
        path = os.path.join(DST, name)
        with io.open(path, "w", encoding="ascii", newline="\n") as f:
            for v in vals:
                f.write("%02x\n" % (v & 0xFF))
        print("%-16s %5d samples  %d block RAMs" % (name, len(vals), -(-len(vals) // 2048)))

    print()
    print("parameters for src/misc/drive_sound.v:")
    print("  HUM_LEN      = %d" % len(res["hum"]))
    print("  STEP_IN_LEN  = %d" % len(res["step_in"]))
    print("  STEP_OUT_OFF = %d" % len(res["step_in"]))
    print("  STEP_OUT_LEN = %d" % len(res["step_out"]))
    print("  BANG_OFF     = %d" % (len(res["step_in"]) + len(res["step_out"])))
    print("  BANG_LEN     = %d" % len(res["bang"]))
    print("  HEAD_LEN     = %d" % len(banks["drive_head.hex"]))
    print()
    print("peaks after resampling, which is what the gains are set from:")
    for k in ("hum", "step_in", "step_out", "bang"):
        print("  %-9s %4d .. %4d" % (k, min(res[k]), max(res[k])))


if __name__ == "__main__":
    main()
