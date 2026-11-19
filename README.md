# tx6rec

A norns mod that records every input of a teenage engineering TX-6 as its own
stereo track, over USB, while any script runs.

## Use

1. Connect the TX-6 to the norns with a USB-C **data** cable (many cables only charge).
2. SYSTEM > MODS, select TX6REC, turn E3 right to enable it, then SYSTEM > RESTART.
3. SYSTEM > MODS > TX6REC > K3: **K3** starts and stops recording, **K2** goes back.
   Recording keeps going when you leave the menu or load another script.

When you stop, the take is split into one 24-bit 48 kHz stereo WAV per TX-6 input:

```
dust/audio/tx6/2026-11-19_130512/2026-11-19_130512_in1.wav
                                 2026-11-19_130512_in2.wav
                                 ...
```

Inputs that sent only digital silence for the whole take (nothing plugged in)
are skipped. The date is in each file name too, so files stay identifiable
once they're dragged into a DAW. Fetch them over SMB/SFTP like any other norns audio.

## How it works

- The TX-6 is a class-compliant USB card with 12 capture channels: TX-6 input
  *n* arrives on channels 2*n*−1 and 2*n*. There's no master mix on USB.
- `lib/rec.sh` reads the card straight from ALSA with `arecord` and writes raw
  PCM. It doesn't use JACK or the norns audio engine, so norns audio, TAPE and
  the clock are untouched, and nothing needs installing (`arecord` and `sox`
  ship with norns).
- Raw PCM has no 4 GB limit and nothing to finalize, so a crash or power cut
  loses nothing: leftover takes are split at the next startup.
- If the USB stream drops out (the TX-6 occasionally refuses the first read),
  the recorder restarts within a fraction of a second and appends to the same
  take; the page counts dropouts. Five failures in a row stop the take.
- Splitting runs at the lowest CPU and disk priority, so scripts keep their timing.
- Disk use is 1.73 MB/s while recording (about 6.2 GB an hour). The page shows
  the time left, with room reserved for the split, and the take stops on its
  own when the disk is nearly full.

## Not included (yet)

- Level meters per input.
- A recording indicator on script screens; check the mod page.
- The norns' own output as a track. Run the norns audio out into a TX-6 input instead.

## Develop

`tools/deploy.sh` syncs to the norns; `tools/deploy.sh --restart` also restarts
the norns software so the mod reloads. `tools/repl.py` is a small matron REPL client.
