#!/usr/bin/env python3
"""Fail closed unless the effective sandbox satisfies its promised boundary."""
import errno
import os
import socket
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit("CI isolation refused: " + message)


allowed = {"PATH", "HOME", "TMPDIR", "LC_ALL", "TZ", "PWD", "OLDPWD", "SHLVL", "_"}
require(not (set(os.environ) - allowed), "unexpected inherited environment")
for descriptor in Path("/proc/self/fd").iterdir():
    try:
        target = os.readlink(descriptor)
    except FileNotFoundError:
        continue  # The directory iterator's own short-lived descriptor.
    require(int(descriptor.name) <= 2, "unexpected inherited file descriptor: " + target)
names = [line.split(":", 1)[0].strip() for line in Path("/proc/self/net/dev").read_text().splitlines() if ":" in line]
require(names == ["lo"], "unexpected network interface")
status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
# Bubblewrap drops effective/permitted/inheritable/ambient capabilities. Linux
# may retain the bounding ceiling; NoNewPrivs prevents gaining privileges later.
for field in ("CapInh", "CapPrm", "CapEff", "CapAmb"):
    require(int(status[field].strip(), 16) == 0, "capabilities not fully dropped")
require(status["NoNewPrivs"].strip() == "1", "no-new-privileges is not active")
for directory in ("/", "/src", "/usr", "/ci"):
    require(os.statvfs(directory).f_flag & os.ST_RDONLY, "writable mount: " + directory)
for directory in ("/tmp", "/run"):
    require(not os.statvfs(directory).f_flag & os.ST_RDONLY, "missing disposable writable mount")
    mounts = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()]
    require(any(fields[4] == directory and fields[fields.index("-") + 1] == "tmpfs" for fields in mounts), "writable directory is not tmpfs")
require(not Path("/home").exists() and not Path("/root").exists(), "host homes exposed")
git = Path("/src/.git")
if git.is_dir():
    require(not list(git.iterdir()), "Git metadata exposed")
elif git.is_file():
    require(git.read_bytes() == b"", "Git metadata exposed")

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    with socket.create_connection(listener.getsockname(), timeout=2) as client:
        peer, _ = listener.accept()
        peer.close()
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as external:
    external.settimeout(1)
    result = external.connect_ex(("198.51.100.1", 443))
    require(result in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.EACCES, errno.EPERM), "external route was not rejected")
print("PASS: CI isolation self-test (clean environment, no capabilities, read-only sources, private tmp, loopback only)")
