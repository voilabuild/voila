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
    rows: list[dict[str, str]] = []
    for line in v.run("ps").err.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        pid = parts[-1]
        if parts[-2].startswith("(") and len(parts) >= 6:
            status = f"{parts[-3]} {parts[-2]}"
            image, name, cid = parts[-4], parts[-5], parts[0]
        else:
            cid, name, image, status = parts[0], parts[1], parts[2], parts[3]
        rows.append({"id": cid, "name": name, "image": image, "status": status, "pid": pid})
    return rows


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
    assert containers(voila)[0]["status"].startswith("exited")
    voila.run("rm", "victim")


def test_ps_shows_exit_code_for_missing_command(voila: Voila) -> None:
    voila.run("import", BASE)
    voila.run("run", "-d", "--name", "bad", BASE, "--", "nosuchcmd", check=False)
    assert wait_until(
        lambda: any(c["name"] == "bad" and "127" in c["status"] for c in containers(voila))
    ), containers(voila)
    voila.run("rm", "bad", check=False)


def test_rm_removes_every_id(voila: Voila) -> None:
    voila.run("import", BASE)
    voila.run("run", "-d", "--name", "a", BASE, "--", "sleep", "30")
    voila.run("run", "-d", "--name", "b", BASE, "--", "sleep", "30")
    assert wait_until(lambda: {c["name"] for c in containers(voila)} >= {"a", "b"})
    voila.run("rm", "a", "b")
    names = {c["name"] for c in containers(voila)}
    assert "a" not in names and "b" not in names


def test_rm_removes_a_container_that_ran_as_nobody(voila: Voila, tmp_path: Path) -> None:
    voila.run("import", BASE)
    ctx = tmp_path / "nobody"
    ctx.mkdir()
    (ctx / "Dockerfile").write_text("FROM alpine:3.20\nUSER nobody\n")
    voila.run("build", "-t", "as-nobody:1", str(ctx))
    # /tmp is mode 1777 and owned by root, so nobody can create this directory.
    # The directory itself is then owned by nobody's subordinate id.
    voila.run("run", "--name", "u", "as-nobody:1", "--", "mkdir", "-p", "/tmp/nested/dir")
    voila.run("rm", "u")
    assert containers(voila) == []
    assert [p.name for p in (voila.root / "containers").iterdir() if p.is_dir()] == []


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
