"""Bounded, retrying libvirt serial-console capture for integration tests."""

import errno
import os
import pathlib
import pty
import select
import signal
import sys
import time
from types import FrameType

ACTIVE_PID: int | None = None


def forward_signal(signum: int, _frame: FrameType | None) -> None:
    if ACTIVE_PID is None:
        return
    try:
        os.killpg(ACTIVE_PID, signum)
    except ProcessLookupError:
        pass


def read_attempt(
    command: list[str],
    deadline: float,
    captured: bytearray,
    marker: bytes,
    expected_count: int,
) -> int:
    global ACTIVE_PID
    pid, master_fd = pty.fork()
    ACTIVE_PID = pid
    if pid == 0:
        os.execvp(command[0], command)

    marker_reached = False
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master_fd], [], [], 0.5)
            if not readable:
                child_pid, status = os.waitpid(pid, os.WNOHANG)
                if child_pid:
                    ACTIVE_PID = None
                    return os.waitstatus_to_exitcode(status)
                continue
            try:
                data = os.read(master_fd, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            captured.extend(data)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            if marker and captured.count(marker) >= expected_count:
                marker_reached = True
                forward_signal(signal.SIGTERM, None)
                break
    finally:
        os.close(master_fd)

    if time.monotonic() >= deadline:
        forward_signal(signal.SIGTERM, None)
    _, status = os.waitpid(pid, 0)
    ACTIVE_PID = None
    return 0 if marker_reached else os.waitstatus_to_exitcode(status)


def main() -> int:
    uri, domain, marker_text, count_text, ready_path = sys.argv[1:]
    expected_count = int(count_text)
    command = [
        "timeout",
        "60",
        "virsh",
        "-c",
        uri,
        "console",
        domain,
        "--devname",
        "serial0",
        "--force",
    ]
    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    if ready_path:
        pathlib.Path(ready_path).write_text("ready\n", encoding="utf-8")

    deadline = time.monotonic() + 70
    captured = bytearray()
    marker = marker_text.encode()
    while time.monotonic() < deadline:
        status = read_attempt(command, deadline, captured, marker, expected_count)
        if marker and captured.count(marker) >= expected_count:
            return 0
        if not marker:
            return status
        time.sleep(0.2)
    return 124


if __name__ == "__main__":
    raise SystemExit(main())
