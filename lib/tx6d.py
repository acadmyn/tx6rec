#!/usr/bin/env python3
"""tx6rec engine: reads the TX-6 while the mod page is open (for the meters)
or a take is running, and writes audio to disk only during a take.

    tx6d.py <shm dir> <state dir> <rec.sh>

Files in <shm dir> (tmpfs, so nothing here wears the SD card):
  rec     written by the mod: the raw file to record to. Removed to stop.
  hb      touched by the mod page; with no take running and no heartbeat
          for HB_TIMEOUT seconds, the engine exits.
  levels  "seq p1 .. p12": per-channel peaks of the last WINDOW, 0-127 from
          each sample's top byte (127 = clipping)
  status  state, raw, start, glitches, dropped, buffered, bytes, free, reason
  pid

Quirks of norns + TX-6, all measured:
- About 1 in 4 arecord starts stall after one period and ignore SIGINT for
  ~12 s. A watchdog kills arecord after STALL seconds without audio and
  starts it again. Keeping the stream running between takes means pressing
  record never waits on a fresh start.
- A stream can start with ~0.2 ms of junk on every channel, so the first
  20 ms of each start are dropped.
- Killing arecord mid-write can leave a partial frame, which would shift
  every later channel, so only whole frames are passed on.
- The SD card pauses writes for up to ~3 s, longer than the ALSA buffer, so
  take audio is queued in RAM and written by its own thread.
"""
import fcntl, os, queue, subprocess, sys, threading, time

ARECORD = ["arecord", "-q", "-D", "hw:TX6", "-c", "12", "-f", "S24_3LE",
           "-r", "48000", "-t", "raw", "-F", "20000", "-B", "500000"]
FRAME = 12 * 3            # bytes per sample frame
SKIP = 960 * FRAME        # first 20 ms of every stream
STALL = 0.3               # seconds without audio before restarting arecord
GIVE_UP = 10              # restarts in a row without audio: TX-6 is gone
WINDOW = 0.08             # level window (one tape column on the page)
HB_TIMEOUT = 10
RESERVE = 256 << 20       # keep this much disk free beyond the split's needs
MAX_QUEUE = 1 << 30       # RAM for take audio while the SD card is busy
# top byte of a signed 24-bit sample -> absolute value 0..127
ABS = bytes(min(127, b if b < 128 else 256 - b) for b in range(256))

shm, state, recsh = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(shm, exist_ok=True)
P = lambda name: os.path.join(shm, name)


def write_kv(path, **kv):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for k, v in kv.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, path)


def log(msg):
    with open(os.path.join(state, "log"), "a") as f:
        f.write(time.strftime("%F %T ") + msg + "\n")


class Take:
    def __init__(self, raw):
        self.raw = raw
        self.q = queue.Queue()
        self.queued = 0
        self.bytes = 0
        self.dropped = 0
        self.glitches = 0
        self.start = time.time()
        os.makedirs(os.path.dirname(raw), exist_ok=True)
        self.fd = os.open(raw, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        self.w = threading.Thread(target=self.writer)
        self.w.start()

    def put(self, chunk):  # called with lock held
        if self.queued > MAX_QUEUE:
            self.dropped += len(chunk)
            return
        self.queued += len(chunk)
        self.bytes += len(chunk)
        self.q.put(chunk)

    def writer(self):
        while True:
            chunk = self.q.get()
            if chunk is None:
                break
            os.write(self.fd, chunk)
            with lock:
                self.queued -= len(chunk)
        os.close(self.fd)

    def finish(self):
        self.q.put(None)
        self.w.join()  # drain RAM to disk before the split reads the file


lock = threading.Lock()
peaks = [0] * 12
take = None
last_data = time.monotonic()
got_data = False


def reader(proc):
    global last_data, got_data
    fd = proc.stdout.fileno()
    carry, skip = b"", SKIP
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            return  # a partial frame left in carry is dropped on purpose
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
            for ch in range(12):
                m = max(chunk[ch * 3 + 2::FRAME].translate(ABS))
                if m > peaks[ch]:
                    peaks[ch] = m
            if take:
                take.put(chunk)
        last_data = time.monotonic()
        got_data = True


def start_arecord():
    global last_data, got_data
    got_data = False
    last_data = time.monotonic()
    errlog = open(os.path.join(state, "log"), "a")
    p = subprocess.Popen(ARECORD, stdout=subprocess.PIPE, stderr=errlog, bufsize=0)
    threading.Thread(target=reader, args=(p,), daemon=True).start()
    return p


def kill(p):
    try:
        p.kill()  # raw output has no header, so SIGKILL loses nothing
    except ProcessLookupError:
        pass
    p.wait()


def free_bytes(path):
    s = os.statvfs(path)
    return s.f_bavail * s.f_frsize


def status(st, reason=""):
    t = take
    write_kv(P("status"), state=st, raw=t.raw if t else "", start=int(t.start) if t else 0,
             glitches=t.glitches if t else 0, dropped=t.dropped if t else 0,
             buffered=t.queued if t else 0, bytes=t.bytes if t else 0,
             free=free_bytes(os.path.dirname(t.raw)) if t else 0, reason=reason)


def begin(raw):
    global take
    with lock:
        take = Take(raw)
    log(f"start {raw}")
    status("recording")


def end(reason=""):
    global take
    with lock:
        t, take = take, None
    t.finish()
    log(f"stop {t.raw}" + (f" ({reason})" if reason else ""))
    # the split outlives this process; its progress goes to <shm>/split
    subprocess.Popen(["bash", recsh, "split", t.raw, state, shm, reason],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    status("monitor", reason)


def main():
    # one engine at a time: python can take seconds to start on a busy norns,
    # so the mod may launch a second copy before the first has said hello
    lockf = open(P("lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    with open(P("pid"), "w") as f:
        f.write(str(os.getpid()))
    open(P("hb"), "a").close()
    os.utime(P("hb"))
    p = start_arecord()
    fails, seq, lost = 0, 0, False
    next_win = next_status = time.monotonic()
    status("monitor")
    while True:
        time.sleep(0.02)
        now = time.monotonic()
        # watchdog
        dead = p.poll() is not None
        if dead or now - last_data > STALL:
            fails = 0 if got_data else fails + 1
            kill(p)
            if fails >= GIVE_UP:
                lost = True
                break
            if take and take.bytes:
                take.glitches += 1
            log("arecord exited, restarting" if dead else "stream stalled, restarting")
            time.sleep(0.1)
            p = start_arecord()
            continue
        # start / stop requests from the mod
        want = os.path.exists(P("rec"))
        if want and not take:
            try:
                with open(P("rec")) as f:
                    raw = f.read().strip()
                if raw:
                    begin(raw)
            except OSError as e:
                log(f"cannot start take: {e}")
                os.remove(P("rec"))
        elif take and not want:
            end()
        # levels
        if now >= next_win:
            next_win = now + WINDOW
            seq += 1
            with lock:
                line = f"{seq} " + " ".join(map(str, peaks)) + "\n"
                for i in range(12):
                    peaks[i] = 0
            with open(P("levels.tmp"), "w") as f:
                f.write(line)
            os.replace(P("levels.tmp"), P("levels"))
        # status, disk space, heartbeat
        if now >= next_status:
            next_status = now + 1
            if take:
                if free_bytes(os.path.dirname(take.raw)) < take.bytes + RESERVE:
                    os.remove(P("rec"))
                    end("disk full")
                else:
                    status("recording")
            else:
                try:
                    hb_age = time.time() - os.path.getmtime(P("hb"))
                except OSError:
                    hb_age = HB_TIMEOUT + 1
                if hb_age > HB_TIMEOUT:
                    break
    kill(p) if not lost else None
    if take:
        try:
            os.remove(P("rec"))
        except OSError:
            pass
        end("TX-6 lost")
    status("off", "TX-6 lost" if lost else "")
    os.remove(P("pid"))


if __name__ == "__main__":
    main()
