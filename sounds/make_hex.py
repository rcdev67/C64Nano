#!/usr/bin/env python3
"""Turn snds1541.bin into the two hex files src/misc/drive_sound.v reads.

    py -3 sounds/make_hex.py

Writes src/misc/drive_motor.hex and src/misc/drive_head.hex. Both are generated
-- edit this script, never them. Run it from the repository root.

The player holds the samples in block RAM, and this core leaves exactly four of
its 46 free: two for each memory, 4096 bytes each.

    drive_motor.hex  hum | slip, 2048 + 2048 = 4096   two loops
    drive_head.hex   step in | step out | bang = 3200 one-shots

Both loops are kept, because they are not interchangeable. The original player
picks the hum when the drive runs empty and the slipping sound when a disk is
in, since the disk rubs against the liner of its sleeve -- and a disk is always
in while something loads. Dropping the slip loop, as the first version of this
script did, kept the one sound a loading 1541 never makes.

At 11025 Hz each loop is 2205 samples, 200 ms. Cut to 2048 they fit exactly, and
2048 being a power of two lets the player's loop counter wrap by itself, with no
comparison that could be wrong. The 157 samples that are left over are not
thrown away: they crossfade into the start of the loop, so the cut does not
click five times a second.

11025 and not 8000 Hz, because at 8 kHz the averaging filter takes the bite out
of a step -- its peak drops from 26 to 13 -- and the clack is what the whole
thing exists for. Averaged over each input window rather than picking every
n-th sample: the set has content above 5 kHz, and dropping samples folds it
back down as a hiss.
"""

import io
import os
import sys

IN_HZ = 22050
OUT_HZ = 11025
LOOP_LEN = 2048          # per loop, a power of two

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
        out.append(max(-128, min(127, int(round(acc / (i1 - i0))))))
    return out


def loop(src, length):
    """A seamless loop of `length` samples from a longer source.

    The first `fade` samples are blended with the ones just past the cut, so
    the sample after the wrap continues where the source would have gone on:
    out[L-1] = src[L-1] and out[0] = src[L]."""
    fade = len(src) - length
    if fade <= 0:
        sys.exit("source of %d samples is too short for a loop of %d" % (len(src), length))
    out = list(src[:length])
    for i in range(fade):
        w = i / fade
        out[i] = int(round(src[i] * w + src[length + i] * (1.0 - w)))
    return out


def main():
    data = open(SRC, "rb").read()
    if len(data) != 46336:
        sys.exit("%s is %d bytes, expected 46336" % (SRC, len(data)))

    res = {k: resample(data[o:o + l]) for k, (o, l) in PARTS.items()}
    hum = loop(res["hum"], LOOP_LEN)
    slip = loop(res["slip"], LOOP_LEN)

    # One memory per channel, sounds stored back to back, so that neither
    # memory is ever read from two places at once.
    banks = {
        "drive_motor.hex": hum + slip,
        "drive_head.hex": res["step_in"] + res["step_out"] + res["bang"],
    }

    for name, vals in banks.items():
        if len(vals) > 4096:
            sys.exit("%s: %d samples do not fit two block RAMs" % (name, len(vals)))
        path = os.path.join(DST, name)
        with io.open(path, "w", encoding="ascii", newline="\n") as f:
            for v in vals:
                f.write("%02x\n" % (v & 0xFF))
        print("%-16s %5d samples  %d block RAMs" % (name, len(vals), -(-len(vals) // 2048)))

    print()
    print("parameters for src/misc/drive_sound.v:")
    print("  LOOP_BITS    = %d   (hum at 0, slip at %d)" % (LOOP_LEN.bit_length() - 1, LOOP_LEN))
    print("  STEP_IN_LEN  = %d" % len(res["step_in"]))
    print("  STEP_OUT_OFF = %d" % len(res["step_in"]))
    print("  STEP_OUT_LEN = %d" % len(res["step_out"]))
    print("  BANG_OFF     = %d" % (len(res["step_in"]) + len(res["step_out"])))
    print("  BANG_LEN     = %d" % len(res["bang"]))
    print("  HEAD_LEN     = %d" % len(banks["drive_head.hex"]))
    print()
    print("peaks, which is what the gains are set from:")
    for k, v in (("hum", hum), ("slip", slip), ("step_in", res["step_in"]),
                 ("step_out", res["step_out"]), ("bang", res["bang"])):
        print("  %-9s %4d .. %4d" % (k, min(v), max(v)))
    for k, v in (("hum", hum), ("slip", slip)):
        print("  %s seam: last %d, first %d" % (k, v[-1], v[0]))


if __name__ == "__main__":
    main()
