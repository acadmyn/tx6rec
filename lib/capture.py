#!/usr/bin/env python3
"""Capture the TX-6 to a raw file until <state>/stop exists.

    capture.py <raw file> <state dir>

Two problems measured on norns + TX-6 that plain `arecord > file` can't handle:
- About 1 in 4 starts stall: the TX-6 sends one period, then nothing, and
  arecord hangs ~12 s (ignoring SIGINT) before an I/O error. A watchdog kills
  arecord when no audio arrives for STALL seconds and starts it again.
- Killing arecord mid-write can leave a partial frame, which would shift all
  later channels, so only whole frames go to disk.
- A stream can start with ~0.2 ms of junk on every channel (a click, and it
  makes empty inputs look used), so the first 20 ms of each start are dropped.
- The SD card pauses writes for up to ~3 s, longer than the ALSA buffer, which
  drops audio. Audio is queued in RAM and written by a separate thread.

Writes <state>/capture (glitches, buffered bytes) and <state>/reason on failure.
Exit code 0 when stopped, 1 when the TX-6 was lost.
"""
import os, queue, signal, subprocess, sys, threading, time

ARECORD = ["arecord", "-q", "-D", "hw:TX6", "-c", "12", "-f", "S24_3LE",
           "-r", "48000", "-t", "raw"]
STALL = 0.3          # seconds without audio (first period arrives in ~0.13 s)
FRAME = 12 * 3       # bytes per sample frame; the file must stay frame-aligned
SKIP = 960 * FRAME   # first 20 ms of every stream: the TX-6 sends a few junk frames
GIVE_UP = 10         # consecutive restarts without any audio: TX-6 is gone
MAX_QUEUE = 1 << 30  # 1 GB (~10 min of audio) in RAM before dropping

raw_path, state = sys.argv[1], sys.argv[2]
stop_path = os.path.join(state, "stop")

q = queue.Queue()
queued = 0           # bytes waiting for the disk
lock = threading.Lock()
last_data = time.monotonic()
got_data = False     # since the current arecord started
dropped = 0
total = 0            # bytes received from the TX-6 in this take


def write_kv(name, **kv):
    tmp = os.path.join(state, name + ".tmp")
    with open(tmp, "w") as f:
        for k, v in kv.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, os.path.join(state, name))


def writer():
    global queued
    fd = os.open(raw_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    while True:
        chunk = q.get()
        if chunk is None:
            break
        os.write(fd, chunk)
        with lock:
            queued -= len(chunk)
    os.close(fd)


def reader(proc):
    global last_data, got_data, queued, dropped, total
    fd = proc.stdout.fileno()
    carry = b""
    skip = SKIP
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            # a killed arecord can leave a partial frame; dropping it keeps every
            # later byte on the right channel
            return
        if skip:
            n = min(skip, len(chunk))
            chunk, skip = chunk[n:], skip - n
            if not chunk:
                continue
        chunk = carry + chunk
        cut = len(chunk) - len(chunk) % FRAME
        chunk, carry = chunk[:cut], chunk[cut:]
        if not chunk:
            continue
        with lock:
            if queued > MAX_QUEUE:
                dropped += len(chunk)
                continue
            queued += len(chunk)
            total += len(chunk)
        q.put(chunk)
        last_data = time.monotonic()
        got_data = True


def start():
    global last_data, got_data
    got_data = False
    last_data = time.monotonic()
    log = open(os.path.join(state, "log"), "a")
    p = subprocess.Popen(ARECORD, stdout=subprocess.PIPE, stderr=log, bufsize=0)
    threading.Thread(target=reader, args=(p,), daemon=True).start()
    return p


def kill(p):
    try:
        p.kill()   # raw output has no header, so SIGKILL loses nothing
    except ProcessLookupError:
        pass
    p.wait()


signal.signal(signal.SIGTERM, lambda *_: open(stop_path, "a").close())

w = threading.Thread(target=writer)
w.start()
glitches = 0
fails = 0
lost = False
p = start()
tick = 0
while not os.path.exists(stop_path):
    time.sleep(0.05)
    tick += 1
    dead = p.poll() is not None
    if dead or time.monotonic() - last_data > STALL:
        fails = 0 if got_data else fails + 1
        kill(p)
        if fails >= GIVE_UP:
            lost = True
            break
        if total:
            glitches += 1   # a gap in the take; stalls before the first audio cost nothing
        with open(os.path.join(state, "log"), "a") as f:
            f.write(time.strftime("%F %T") +
                    (" arecord exited" if dead else " stream stalled") + ", restarting\n")
        time.sleep(0.1)
        p = start()
    if tick % 10 == 0:
        write_kv("capture", glitches=glitches, buffered=queued, dropped=dropped)

if not lost:
    kill(p)
q.put(None)
w.join()   # drain RAM to disk before the split starts
write_kv("capture", glitches=glitches, buffered=0, dropped=dropped)
if lost:
    with open(os.path.join(state, "reason"), "w") as f:
        f.write("TX-6 lost\n")
sys.exit(1 if lost else 0)
