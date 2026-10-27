#!/usr/bin/env python3
"""Render what src/misc/drive_sound.v should sound like, as a wav file.

    py -3 sounds/make_preview.py        -> sounds/preview_1541.wav

Reads the generated hex files and applies the same gains, the same shift and the
same envelope as the player, so the result is a prediction and not an
impression. Compare the board against it: if they match, the player is working
and anything left to argue about is the material and the 11 kHz rate. If they
do not match, it is the hardware.

That distinction cost an evening to learn, which is why this script is here.
"""

import io, os, struct, wave

# The same numbers as in src/misc/drive_sound.v
HUM_LEN, STEP_IN_LEN, STEP_OUT_OFF, STEP_OUT_LEN, BANG_OFF, BANG_LEN = \
    2205, 1024, 1024, 1088, 2112, 1088
HUM_GAIN, STEP_IN_GAIN, STEP_OUT_GAIN, BANG_GAIN = 93, 231, 188, 126
OUT_SHIFT = 8
SR = 11025

D = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "misc"))


def rd(name):
    out = []
    for line in io.open(os.path.join(D, name), encoding="ascii"):
        line = line.strip()
        if line:
            v = int(line, 16)
            out.append(v - 256 if v > 127 else v)
    return out


motor = rd("drive_motor.hex")
head = rd("drive_head.hex")
assert len(motor) == HUM_LEN and len(head) == BANG_OFF + BANG_LEN

# Motor on, then a step in, a step out, the head bang, and a seek of eight
# steps 40ms apart as a real one would be.
events = []            # (sample, kind) kind: 0 in, 1 out, 2 bang
t = 0
events.append((int(0.7 * SR), 0))
events.append((int(1.3 * SR), 1))
events.append((int(1.9 * SR), 2))
for k in range(8):     # eine Suche: acht Schritte im Abstand von 40 ms
    events.append((int((2.7 + 0.04 * k) * SR), 0))
N = int(4.2 * SR)

motor_on_from, motor_on_to = int(0.2 * SR), int(3.8 * SR)

frames = bytearray()
motor_env = 0
motor_pos = 0
head_pos = 0
head_snd = 0
head_active = False
ev = dict((s, k) for s, k in events)
peak = 0

for n in range(N):
    on = motor_on_from <= n < motor_on_to
    if on:
        if motor_env < 255:
            motor_env += 1
    elif motor_env > 0:
        motor_env -= 1

    m_s = motor[motor_pos]
    h_s = head[head_pos]

    if n in ev:
        k = ev[n]
        head_snd, head_active = k, True
        head_pos = (0, STEP_OUT_OFF, BANG_OFF)[k]
    elif head_active:
        last = (STEP_IN_LEN - 1, STEP_OUT_OFF + STEP_OUT_LEN - 1, BANG_OFF + BANG_LEN - 1)[head_snd]
        if head_pos == last:
            head_active = False
        else:
            head_pos += 1

    if on or motor_env:
        motor_pos = motor_pos + 1 if motor_pos < HUM_LEN - 1 else 0
    else:
        motor_pos = 0

    h_gain = 0 if not head_active else (STEP_IN_GAIN, STEP_OUT_GAIN, BANG_GAIN)[head_snd]
    m_mul = m_s * HUM_GAIN * motor_env
    h_mul = (h_s * h_gain) << 8
    v = (m_mul + h_mul) >> OUT_SHIFT
    v = max(-32768, min(32767, v))
    peak = max(peak, abs(v))
    frames += struct.pack("<h", v)

p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "preview_1541.wav")
w = wave.open(p, "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
w.writeframes(bytes(frames)); w.close()
print("written:", p)
print("peak in the mixer: %d of 32767" % peak)
