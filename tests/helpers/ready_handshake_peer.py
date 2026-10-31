#!/usr/bin/env python3
"""Real socket/pipe peer for deterministic reader-lifecycle tests.

The peer deliberately controls fragmentation, EOF and a descendant retaining
stderr. It replaces the daemon only in reader tests; editor startup tests run the
actual IsoNim executable and actual agent integration separately.
"""
import os
import signal
import socket
import sys
import time

mode, state = sys.argv[1:3]
if mode == "descriptor_probe":
    import json
    wanted = {tuple(pair) for pair in json.loads(sys.argv[3])}
    inherited = []
    for fd in range(3, 2048):
        try:
            info = os.fstat(fd)
        except OSError:
            continue
        if (info.st_dev, info.st_ino) in wanted:
            inherited.append(fd)
    with open(state, "w") as output:
        json.dump(inherited, output)
    raise SystemExit(0)
if mode == "eof":
    os.write(2, "last Unicode line λ without newline".encode())
    raise SystemExit(3)
if mode == "flood_timeout":
    child = os.fork()
    if child:
        with open(state, "w") as output:
            output.write(str(child))
        while True:
            time.sleep(1)
    block = b"writer retained stderr after its parent died\n" * 100
    try:
        while True:
            os.write(2, block)
    except BrokenPipeError:
        raise SystemExit(0)
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
port = listener.getsockname()[1]
if mode == "malformed":
    for line in ["READY 0", "READY 65536", "READY 123junk", "READY -1", "READY +1"]:
        os.write(2, (line + "\n").encode())
if mode == "flood":
    for i in range(5000):
        os.write(2, ("noise " + str(i) + " " + "x" * 400 + "\n").encode())
    os.write(2, b"REA")
    time.sleep(0.02)
    os.write(2, ("DY " + str(port) + "\n").encode())
else:
    os.write(2, ("READY " + str(port) + "\n").encode())
connection, _ = listener.accept()
connection.recv(4096)
connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
connection.close()
listener.close()
os.write(2, b"tail after ready\n")
