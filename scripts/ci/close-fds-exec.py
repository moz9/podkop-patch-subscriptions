#!/usr/bin/env python3
"""Close inherited nonstandard descriptors before exec; do not relax checks."""
import errno
import os
import signal
import sys


if len(sys.argv) < 2 or not os.path.isabs(sys.argv[1]):
    raise SystemExit("CI descriptor cleanup refused: expected an absolute executable")

# Read the kernel's live descriptor list instead of guessing an RLIMIT ceiling.
# os.listdir closes its directory descriptor before returning. EBADF is therefore
# expected only for that transient descriptor; any other close failure is fatal.
for name in os.listdir("/proc/self/fd"):
    descriptor = int(name)
    if descriptor <= 2:
        continue
    try:
        os.close(descriptor)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise

# Python can install/retain signal handlers; preserve interruption-test behavior
# when replacing it with the sandbox launcher or test shell.
for signum in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
