#!/usr/bin/env python3
"""Drive the interactive first-administrator bootstrap on a real pty.

    bootstrap-driver.py <helper-path> <password> <ps-sample-file>

⚠️ THE PASSWORD IS AN ARGUMENT *TO THIS DRIVER*, AND ONLY HERE. That is
safe and deliberate: the driver exists inside a disposable test container
whose whole filesystem is discarded, and the point of the exercise is to
prove the password does NOT reach the argv of the helper or of `semaphore`.
The driver's own argv is the control, not the thing under test — the
harness asserts the password appears in the driver's command line and in
NO other process.

A pty is required because the helper refuses without an interactive
terminal (`[ -t 0 ] && [ -t 1 ]`) and because `read -rs` needs a terminal
to disable echo on. Feeding it a pipe would not exercise either.

While `semaphore setup` runs, this samples the full process table
repeatedly and writes it out, so the harness can prove the password was
never visible in any process's arguments at any point.
"""
import os
import pty
import re
import select
import subprocess
import sys
import termios
import threading
import time

helper, password, ps_out = sys.argv[1], sys.argv[2], sys.argv[3]

samples = []
stop = threading.Event()
# Records one entry per password prompt whose ECHO bit was observed clear.
echo_off_confirmed = []


def sample_processes():
    """Record every process command line, as fast as is useful."""
    while not stop.is_set():
        try:
            out = subprocess.run(
                ["ps", "-eo", "args"], capture_output=True, text=True, timeout=5
            ).stdout
            samples.append(out)
        except Exception:  # noqa: BLE001 - a failed sample must not stop the run
            pass
        time.sleep(0.05)


sampler = threading.Thread(target=sample_processes, daemon=True)
sampler.start()

pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["/bin/bash", helper])

transcript = b""
# The full, untruncated record. `transcript` below is consumed as prompts
# are matched, so it cannot be used for diagnostics.
full = b""
# The prompts, in the order the helper asks them. Each is answered once.
pending = [
    (re.compile(rb'Type "bootstrap" to continue:'), b"bootstrap\n"),
    (re.compile(rb"Administrator password:"), password.encode() + b"\n"),
    (re.compile(rb"Confirm password:"), password.encode() + b"\n"),
]

deadline = time.time() + 300
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        transcript += chunk
        full += chunk
        if pending and pending[0][0].search(transcript):
            # ⚠️ FOR A PASSWORD PROMPT, WAIT UNTIL ECHO IS ACTUALLY OFF.
            # The first version typed the instant the prompt appeared and
            # the pty echoed the password straight back — bash had not yet
            # reached the tcsetattr inside `read -rs`. That looked exactly
            # like a real echo leak.
            #
            # A sleep would hide the race rather than resolve it, so this
            # polls the terminal attributes and only types once the ECHO
            # bit is genuinely clear. If it never clears, `read -s` is not
            # doing its job and the run fails for a real reason.
            if b"password" in pending[0][0].pattern.lower():
                waited = 0.0
                while waited < 5.0:
                    if not (termios.tcgetattr(fd)[3] & termios.ECHO):
                        break
                    time.sleep(0.02)
                    waited += 0.02
                else:
                    print("DRIVER: ECHO never cleared before a password prompt")
                    stop.set()
                    os.kill(pid, 9)
                    sys.exit(3)
                echo_off_confirmed.append(True)
            os.write(fd, pending[0][1])
            # Drop the matched prompt so a later identical one is not
            # answered twice.
            transcript = pending[0][0].split(transcript)[-1]
            pending.pop(0)
    else:
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                break
        except ChildProcessError:
            break

try:
    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
except ChildProcessError:
    rc = 0

stop.set()
sampler.join(timeout=2)

with open(ps_out, "w") as fh:
    fh.write("".join(samples))

print(f"DRIVER: {len(samples)} process-table samples taken")
print(f"DRIVER: helper exit {rc}")

# ⚠️ ALWAYS PRINT WHAT THE HELPER SAID. The first version swallowed the pty
# transcript, so a refusal surfaced only as "exit 2" with no reason — the
# harness could see that something was wrong and nothing about what. The
# transcript cannot contain the password: echo is off for both prompts, and
# the harness asserts that separately.
print(f"DRIVER: echo-off confirmed at {len(echo_off_confirmed)} password prompt(s)")
print("DRIVER: ---- helper transcript ----")
sys.stdout.write(full.decode("utf-8", "replace"))
print("DRIVER: ---- end transcript ----")
sys.exit(rc)
