#!/usr/bin/env python3
"""Minimal matron REPL client (stdlib only).

Usage:
  tools/repl.py 'print("hi")'            # send lua, print output for 2s
  tools/repl.py -t 10 'norns.script.load("code/lagom/lagom.lua")'
  tools/repl.py -t 120 --listen           # just print matron output
"""
import argparse, base64, os, select, socket, sys, time

HOST = os.environ.get("NORNS_HOST", "norns.tretiotre.local")
PORT = 5555


def connect():
    s = socket.create_connection((HOST, PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: bus.sp.nanomsg.org\r\n\r\n"
    )
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    head, rest = buf.split(b"\r\n\r\n", 1)
    if b" 101 " not in head.split(b"\r\n")[0]:
        sys.exit("handshake failed: " + head.decode(errors="replace"))
    return s, rest


def send_text(s, text):
    payload = text.encode()
    mask = os.urandom(4)
    hdr = bytearray([0x81])
    n = len(payload)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126); hdr += n.to_bytes(2, "big")
    else:
        hdr.append(0x80 | 127); hdr += n.to_bytes(8, "big")
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def frames(s, buf, deadline):
    while time.time() < deadline:
        while len(buf) >= 2:
            n = buf[1] & 0x7F; off = 2
            if n == 126:
                if len(buf) < 4: break
                n = int.from_bytes(buf[2:4], "big"); off = 4
            elif n == 127:
                if len(buf) < 10: break
                n = int.from_bytes(buf[2:10], "big"); off = 10
            if len(buf) < off + n: break
            yield buf[off:off + n].decode(errors="replace")
            buf = buf[off + n:]
        r, _, _ = select.select([s], [], [], 0.1)
        if r:
            chunk = s.recv(65536)
            if not chunk: return
            buf += chunk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("code", nargs="?")
    ap.add_argument("-t", "--time", type=float, default=2.0)
    ap.add_argument("--listen", action="store_true")
    a = ap.parse_args()
    s, rest = connect()
    if a.code:
        send_text(s, a.code + "\n")
    for f in frames(s, rest, time.time() + a.time):
        sys.stdout.write(f); sys.stdout.flush()


if __name__ == "__main__":
    main()
