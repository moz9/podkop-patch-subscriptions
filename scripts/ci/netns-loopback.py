#!/usr/bin/env python3
"""Require a new, empty network namespace, enable only loopback, then exec."""
import fcntl
import os
import signal
import socket
import struct
import sys


def fail(message):
    raise SystemExit("CI isolation refused: " + message)


if len(sys.argv) < 3:
    fail("missing parent namespace or command")
if os.readlink("/proc/self/ns/net") == sys.argv[1]:
    fail("network namespace was not replaced")
with open("/proc/self/net/dev", encoding="ascii") as interfaces:
    names = [line.split(":", 1)[0].strip() for line in interfaces if ":" in line]
if names != ["lo"]:
    fail("unexpected network interface")

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as control:
    current = fcntl.ioctl(control, 0x8913, struct.pack("16sH14s", b"lo", 0, b""))
    flags = struct.unpack("16sH14s", current)[1]
    fcntl.ioctl(control, 0x8914, struct.pack("16sH14s", b"lo", flags | 1, b""))
    current = fcntl.ioctl(control, 0x8913, struct.pack("16sH14s", b"lo", 0, b""))
    if not struct.unpack("16sH14s", current)[1] & 1:
        fail("loopback did not come up")

with open("/proc/net/route", encoding="ascii") as routes:
    if len(routes.read().strip().splitlines()) > 1:
        fail("unexpected IPv4 route")

print("CI isolation: new network namespace, loopback only, no external route", flush=True)
# A caller may have launched the wrapper asynchronously. Shell background jobs
# can inherit ignored INT/QUIT, which would invalidate interruption fixtures.
for signum in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, signal.SIG_DFL)
os.execv(sys.argv[2], sys.argv[2:])
