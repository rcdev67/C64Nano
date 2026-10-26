# 1541 drive sound samples

`snds1541.bin` is not ours. It is the drive sound set from the **1541 Ultimate**
firmware by **Gideon Zweijtzer**, recorded from a real Commodore 1541:

* Source: <https://github.com/GideonZ/1541ultimate>, `roms/snds1541.bin`
* Licence: **GPL-3.0**, the licence of that repository (`LICENSE.txt`, plain
  GPLv3 with no added terms, and no separate notice in its `roms/` directory).
  This core is GPL-3.0 as well, so the set is used here under the same licence.
* Unchanged: the file is a byte for byte copy, 46336 bytes.

The same repository carries `snds1571.bin` and `snds1581.bin` for the 1571 and
the 1581, in the same format, should another drive ever be wanted.

## What is in it

8 bit signed PCM at 22050 Hz, seven sounds at fixed offsets. The layout is not
written down in the firmware's documentation -- it is in
`fpga/1541/vhdl_source/mm_drive.vhd`, where the player is instantiated, and the
measured levels below confirm it:

| sound | offset | length | level |
|---|---|---|---|
| motor hum, **looped** | `0x0000` | 4410 = 200 ms | -29 .. +28 |
| disk slipping in its sleeve, **looped** | `0x1200` | 4410 = 200 ms | -99 .. +79 |
| head step inwards | `0x2400` | 2048 = 93 ms | -32 .. +31 |
| head step outwards | `0x2C00` | 2176 = 99 ms | -35 .. +33 |
| **head against the end stop** | `0x3480` | 2176 = 99 ms | **-128 .. +100** |
| disk inserted | `0x3D00` | 16384 = 743 ms | -94 .. +76 |
| disk removed | `0x7D00` | 14336 = 650 ms | -76 .. +59 |

Two details are worth knowing, because they are the reason this set sounds like
the real thing and a hand-made one would not.

**The drive sounds different with and without a disk.** The original player
picks the hum when the drive runs empty and the slipping sound when a disk is
in, because the disk rubs against the liner of its sleeve. That is two looped
sounds, not one.

**The head banging against the end stop is the loudest thing in the set**, by a
wide margin, and the player scales the head channel by 16 on top of that. That
is not a mistake: the clatter of a 1541 seeking to track 1 is what the machine
actually sounds like from the next room, and the hum is only a background to it.

## How it gets into the machine

The file goes on the SD card. The companion loads it like any other image, into
the SDRAM, and `src/misc/drive_sound.vhd` plays it from there -- see that file's
header for why it is not held in block RAM.
