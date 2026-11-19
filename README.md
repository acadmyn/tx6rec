# tx6rec

A norns mod that records every input of a teenage engineering TX-6 as its own
track, over USB, while any script runs.

## Setup

1. Connect the TX-6 to the norns with a USB-C **data** cable (many cables only charge).
2. SYSTEM > MODS, select TX6REC, turn E3 right to enable it, then SYSTEM > RESTART.
3. Open it from SYSTEM > MODS > TX6REC (K3).

## Use

The home screen shows six tape lanes, one per TX-6 input, with level meters
at the right edge. While recording the lanes scroll and draw each input's
waveform. A clipping input flashes its number.

- **Home:** E2 picks REC, SETUP or TAKES in the footer, K3 acts (record/stop
  on REC), K2 goes back to the MODS list. A take keeps going when you leave
  the menu or load another script.
- **Setup:** E2 picks a row, E3 changes it. K3 on the name opens the text entry
  (a USB keyboard works there). Changes made during a take apply when you stop.
  - **name**: used for the folder and the file names.
  - **input 1–6**: `stereo` (one stereo file), `mono` (one mono file from the
    left channel, where the TX-6 puts a mono cable), `2x mono` (left and right
    as two mono files, for two sources on a splitter cable) or `off`.
  - **skip silent**: skip inputs that were pure digital silence for the whole take.
- **Takes:** newest first, with time and length; the bottom line shows the
  inputs and size. K3 deletes the selected take after asking.

Files are 24-bit 48 kHz WAVs:

```
dust/audio/tx6/lvscl/lvscl_2026-11-19_1343_in1.wav    stereo
                     lvscl_2026-11-19_1343_in2.wav    mono
                     lvscl_2026-11-19_1343_in6L.wav   2x mono
                     lvscl_2026-11-19_1343_in6R.wav
```

## How it works

- The TX-6 is a class-compliant USB card with 12 capture channels: TX-6 input
  *n* arrives on channels 2*n*−1 and 2*n*. There's no master mix on USB.
- `lib/tx6d.py` reads the card with `arecord` while the mod page is open (for
  the meters) or a take runs, and exits 10 s after you leave the page when idle.
  Because the stream is already running, pressing record starts the take at once.
  It doesn't use JACK or the norns audio engine, and nothing needs installing
  (`arecord`, `sox` and `python3` ship with norns).
- Takes are written as raw PCM: no 4 GB limit and nothing to finalize, so a
  crash or power cut loses nothing; leftover takes are split at the next startup.
- It works around quirks measured on norns + TX-6: about 1 in 4 stream starts
  stall (arecord is restarted after 0.3 s without audio), each start has
  ~0.2 ms of junk (the first 20 ms are dropped), and the SD card pauses writes
  for up to 3 s (take audio waits in RAM meanwhile).
- `lib/rec.sh` splits a stopped take at the lowest CPU and disk priority, so
  scripts keep their timing. The page is drawn into a Lua framebuffer and sent
  with one `screen.poke` per frame, like lagom, for the same reason.
- Disk use is 1.73 MB/s while recording (about 6.2 GB an hour). A take stops on
  its own when the disk is nearly full, leaving room for the split.

## Develop

`tools/deploy.sh` syncs to the norns; `tools/deploy.sh --restart` also restarts
the norns software so the mod reloads, then reloads the script that was running.
`tools/test_engine.sh` (run with `ssh we@norns.local 'bash -s' < tools/test_engine.sh`)
records and splits a short take outside the mod. `tools/repl.py` is a small
matron REPL client; the mod's state is at `_tx6rec.st` and its settings at `_tx6rec.S`.
