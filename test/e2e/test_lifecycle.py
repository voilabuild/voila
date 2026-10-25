"""Container lifecycle: signals, stop, crashed workers and cleanup."""

import os
import signal
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from conftest import VOILA_BIN, Voila

BASE = "alpine:3.20"


def wait_until(cond: Callable[[], bool], timeout: float = 20) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cond():
            return True
        time.sleep(0.1)
    return cond()


def containers(v: Voila) -> list[dict[str, str]]:
    lines = v.run("ps").err.splitlines()[1:]
    keys = ["id", "name", "image", "status", "pid"]
    return [dict(zip(keys, line.split())) for line in lines if line.strip()]


def mounts_under(root: Path) -> list[str]:
    points = (line.split()[4] for line in Path("/proc/self/mountinfo").read_text().splitlines())
    return [p for p in points if p.startswith(str(root))]


def processes_matching(text: str) -> list[int]:
    out: list[int] = []
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            cmd = (d / "cmdline").read_bytes().replace(b"\0", b" ").decode()
        except OSError:
            continue
        if text in cmd:
            out.append(int(d.name))
    return out


def running(v: Voila) -> bool:
    return any(c["status"] == "running" for c in containers(v))


def test_foreground_run_streams_stdout_before_exit(voila: Voila) -> None:
    voila.run("import", BASE)
    p = subprocess.Popen(
        [VOILA_BIN, "run", "--rm", BASE, "--", "sh", "-c", "echo early; sleep 1; echo late"],
        env=voila.env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert p.stdout is not None
    assert p.stdout.readline() == "early\n"
    assert p.poll() is None, "output should stream before the container exits"
    rest = p.stdout.read()
    assert p.wait(timeout=30) == 0
    assert rest == "late\n"


def test_sigterm_to_foreground_run_stops_and_removes_the_container(voila: Voila) -> None:
    voila.run("import", BASE)
    p = subprocess.Popen(
        [VOILA_BIN, "run", "--rm", BASE, "--", "sleep", "3171"],
        env=voila.env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    assert wait_until(lambda: running(voila)), "container never started"
    p.send_signal(signal.SIGTERM)
    p.wait(timeout=30)
    assert containers(voila) == []
    assert mounts_under(voila.root) == []
    assert processes_matching("sleep 3171") == []


def test_stop_lets_the_container_run_its_term_trap(voila: Voila) -> None:
    voila.run("import", BASE)
    script = 'trap "echo trapped; exit 0" TERM; echo ready; while true; do sleep 0.1; done'
    voila.run("run", "-d", "--name", "trap", BASE, "--", "sh", "-c", script)
    assert wait_until(lambda: "ready" in voila.run("logs", "trap").out)
    voila.run("stop", "trap")
    assert "trapped" in voila.run("logs", "trap").out
    voila.run("rm", "trap")
    assert mounts_under(voila.root) == []


def test_killed_worker_leaves_no_mount_or_process(voila: Voila) -> None:
    voila.run("import", BASE)
    voila.run("run", "-d", "--name", "victim", BASE, "--", "sleep", "3172")
    assert wait_until(lambda: running(voila))
    assert all(m.startswith(str(voila.root / "containers")) for m in mounts_under(voila.root))
    worker = int(containers(voila)[0]["pid"])
    os.kill(worker, signal.SIGKILL)
    assert wait_until(lambda: mounts_under(voila.root) == []), mounts_under(voila.root)
    assert wait_until(lambda: processes_matching("sleep 3172") == [])
    assert containers(voila)[0]["status"] == "exited"
    voila.run("rm", "victim")


def test_rm_handles_a_root_with_spaces(voila: Voila, tmp_path: Path) -> None:
    # Before the fix, `sh -c "rm -rf <tmp>/s p/..."` also deleted <tmp>/s.
    sentinel = tmp_path / "s" / "keep"
    sentinel.parent.mkdir()
    sentinel.write_text("x")
    root = tmp_path / "s p" / "root"
    spaced = Voila(root, {**voila.env, "VOILA_ROOT": str(root)})
    spaced.run("import", BASE)
    assert spaced.run("run", "--rm", BASE, "--", "echo", "ok").out == "ok\n"
    assert sentinel.exists()
    assert containers(spaced) == []
    assert [p.name for p in (root / "containers").iterdir() if p.is_dir()] == []
