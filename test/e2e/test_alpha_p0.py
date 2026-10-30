"""Alpha.1 P0s from #130: env, ports, exec, uidmap."""

import os
import shutil
import socket
from pathlib import Path

import pytest

from conftest import Voila, free_port
from test_hello import BASE
from test_lifecycle import containers, mounts_under, wait_until


def test_run_env_is_image_plus_dash_e_not_host(voila: Voila) -> None:
    voila.run("import", BASE)
    voila.env["SOME_HOST_SECRET"] = "leaked"
    res = voila.run(
        "run",
        "--rm",
        "-e",
        "FOO=bar",
        BASE,
        "--",
        "sh",
        "-c",
        'printf "%s %s %s %s" "$FOO" "${SOME_HOST_SECRET-}" "$HOME" "$PATH"',
    )
    out = res.out.strip()
    assert "bar" in out, res.out
    assert "leaked" not in out, res.out
    assert "/home/" not in out, res.out
    assert "/usr/bin" in out, res.out


def test_exec_echo_in_running_container(voila: Voila) -> None:
    voila.run("import", BASE)
    cid = voila.run("run", "-d", BASE, "--", "sleep", "300").out.strip()
    try:
        assert wait_until(lambda: any(c["status"] == "running" for c in containers(voila)))
        assert wait_until(lambda: mounts_under(voila.root) != []), "container never mounted"
        res = voila.run("exec", cid, "--", "/bin/echo", "hi")
        assert res.out.strip() == "hi"
    finally:
        voila.run("stop", cid, check=False)
        voila.run("rm", cid, check=False)


def test_run_uid_map_has_subuid_range(voila: Voila) -> None:
    if shutil.which("newuidmap") is None:
        pytest.skip("newuidmap not installed")
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    subuid = Path("/etc/subuid")
    if not subuid.exists() or (user and user not in subuid.read_text() and str(os.getuid()) not in subuid.read_text()):
        pytest.skip("no subuid range for this user")
    voila.run("import", BASE)
    res = voila.run("run", "--rm", BASE, "--", "cat", "/proc/self/uid_map")
    lines = [ln for ln in res.out.splitlines() if ln.strip()]
    assert len(lines) >= 2, res.out


def test_publish_port_forwards(voila: Voila) -> None:
    if shutil.which("socat") is None:
        pytest.skip("socat not installed")
    voila.run("import", BASE)
    host = free_port()
    cid = voila.run(
        "run",
        "-d",
        "-p",
        f"{host}:8080",
        BASE,
        "--",
        "sleep",
        "300",
    ).out.strip()
    try:
        assert wait_until(lambda: _can_connect(host), timeout=5)
    finally:
        voila.run("stop", cid, check=False)
        voila.run("rm", cid, check=False)


def _can_connect(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), 0.5):
            return True
    except OSError:
        return False
