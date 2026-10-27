#!/usr/bin/env python3
"""Check src/misc/drive_sound.v against a register-for-register model.

Run by run.cmd after the testbench, from src/impl/sim/. Reads tb_out.txt, which
the testbench writes with one line per sample tick:

    motor_on disk_in step_in_seen step_out_seen bang_seen snd

The first five are what the player saw at that tick, so the model works from
exactly the same inputs and nothing depends on lining up two timelines. The
last is what the Verilog produced. Any difference is printed, and the run
fails.

It also writes drive_sound.wav: the Verilog's own output at 11025 Hz, with
the testbench's timing being real time. That file is what the board has to
sound like. If the board matches it, the player works and anything left to
argue about is the material. If it does not match, it is the hardware.

The numbers below must match the parameters of drive_sound.v and what
sounds/make_hex.py prints.
"""
import io
import os
import struct
import sys
import wave

LOOP_BITS = 11
STEP_IN_LEN, STEP_OUT_OFF, STEP_OUT_LEN, BANG_OFF, BANG_LEN = 1024, 1024, 1088, 2112, 1088
MOTOR_GAIN, STEP_IN_GAIN, STEP_OUT_GAIN, BANG_GAIN = 50, 200, 160, 55
HEAD_SHIFT = 9
OUT_SHIFT, MOTOR_TAIL, VOLUME = 7, 1654, 3      # the testbench sets volume 3

HERE = os.path.dirname(os.path.abspath(__file__))
MISC = os.path.normpath(os.path.join(HERE, "..", "..", "src", "misc"))


def rom(name):
    out = []
    for line in io.open(os.path.join(MISC, name), encoding="ascii"):
        line = line.strip()
        if line:
            v = int(line, 16)
            out.append(v - 256 if v > 127 else v)
    return out


def main(log):
    motor_rom, head_rom = rom("drive_motor.hex"), rom("drive_head.hex")
    if len(motor_rom) != 2 << LOOP_BITS:
        sys.exit("drive_motor.hex has %d samples, expected %d" % (len(motor_rom), 2 << LOOP_BITS))

    hold = env = mpos = hpos = hsnd = 0
    hact = False
    ms = hs = 0

    rows = [list(map(int, l.split())) for l in io.open(log) if l.strip()]
    bad = peak = 0
    seen = [0, 0, 0]
    for i, (m_on, disk, s_in, s_out, s_bang, snd_v) in enumerate(rows):
        seen[0] += s_in; seen[1] += s_out; seen[2] += s_bang

        # the output, from the state before this tick
        hg = 0 if not hact else (STEP_IN_GAIN, STEP_OUT_GAIN, BANG_GAIN)[min(hsnd, 2)]
        s = (ms * MOTOR_GAIN * env + ((hs * hg) << HEAD_SHIFT)) >> OUT_SHIFT
        s = 0 if VOLUME == 0 else s >> 2 if VOLUME == 1 else s >> 1 if VOLUME == 2 else s
        snd = max(-32768, min(32767, s))
        peak = max(peak, abs(snd))
        if snd != snd_v:
            bad += 1
            if bad <= 10:
                print("tick %6d: Verilog %6d, model %6d" % (i, snd_v, snd))

        # envelope
        n_hold = MOTOR_TAIL if m_on else (hold - 1 if hold else 0)
        n_env = (env + 1 if env < 255 else env) if hold else (env - 1 if env else 0)

        # playback
        n_ms = motor_rom[(disk << LOOP_BITS) | mpos]
        n_hs = head_rom[hpos]
        n_mpos = (mpos + 1) & ((1 << LOOP_BITS) - 1) if hold else 0
        n_hpos, n_hsnd, n_hact = hpos, hsnd, hact
        if s_bang:
            n_hpos, n_hsnd, n_hact = BANG_OFF, 2, True
        elif s_out:
            n_hpos, n_hsnd, n_hact = STEP_OUT_OFF, 1, True
        elif s_in:
            n_hpos, n_hsnd, n_hact = 0, 0, True
        elif hact:
            last = (STEP_IN_LEN - 1, STEP_OUT_OFF + STEP_OUT_LEN - 1, BANG_OFF + BANG_LEN - 1)[min(hsnd, 2)]
            if hpos == last:
                n_hact = False
            else:
                n_hpos = hpos + 1

        hold, env, ms, hs, mpos, hpos, hsnd, hact = n_hold, n_env, n_ms, n_hs, n_mpos, n_hpos, n_hsnd, n_hact

    wav = os.path.join(os.path.dirname(os.path.abspath(log)), "drive_sound.wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(11025)
        w.writeframes(b"".join(struct.pack("<h", r[5]) for r in rows))

    print("%d ticks compared, %d differences, peak %d of 32767" % (len(rows), bad, peak))
    print("events seen: %d step in, %d step out, %d bang" % tuple(seen))
    print("written: %s, %.2f s" % (wav, len(rows) / 11025))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "tb_out.txt"))
