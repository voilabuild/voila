"""Alpha.1 P0s from #130: env, ports, exec, uidmap, COPY dest, org-slash push."""

import os
import shutil
import socket
from pathlib import Path

import pytest

from conftest import Machine, Registry, Voila, free_port
from test_hello import BASE, write_hello_context
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


def test_unpublished_port_is_not_on_the_host(voila: Voila) -> None:
    voila.run("import", BASE)
    port = free_port()
    cid = voila.run("run", "-d", BASE, "--", "nc", "-l", "-p", str(port)).out.strip()
    try:
        assert wait_until(lambda: any(c["status"] == "running" for c in containers(voila)))
        assert wait_until(lambda: mounts_under(voila.root) != []), "container never mounted"
        assert not _can_connect(port), f"container port {port} leaked onto the host"
        assert any(c["status"] == "running" for c in containers(voila))
    finally:
        voila.run("stop", cid, check=False)
        voila.run("rm", cid, check=False)


def test_two_containers_can_listen_on_the_same_port(voila: Voila) -> None:
    voila.run("import", BASE)
    ids: list[str] = []
    try:
        for _ in range(2):
            ids.append(voila.run("run", "-d", BASE, "--", "nc", "-l", "-p", "5432").out.strip())
        assert wait_until(lambda: sum(1 for c in containers(voila) if c["status"] == "running") >= 2)
        assert not _can_connect(5432)
    finally:
        for cid in ids:
            voila.run("stop", cid, check=False)
            voila.run("rm", cid, check=False)


def test_publish_port_forwards(voila: Voila) -> None:
    voila.run("import", BASE)
    host = free_port()
    cid = voila.run(
        "run",
        "-d",
        "-p",
        f"{host}:8080",
        BASE,
        "--",
        "sh",
        "-c",
        "while true; do nc -l -p 8080; done",
    ).out.strip()
    try:
        assert wait_until(lambda: any(c["status"] == "running" for c in containers(voila)))
        assert wait_until(lambda: _can_connect(host), timeout=8)
    finally:
        voila.run("stop", cid, check=False)
        voila.run("rm", cid, check=False)


def test_detached_publish_fails_if_host_port_busy(voila: Voila) -> None:
    voila.run("import", BASE)
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    host = sock.getsockname()[1]
    try:
        res = voila.run(
            "run", "-d", "-p", f"{host}:8080", BASE, "--", "sleep", "60", check=False
        )
        assert res.rc != 0, res.out + res.err
        assert res.out.strip() == ""
        assert "could not" in res.err
        assert not any(c["status"] == "running" for c in containers(voila))
    finally:
        sock.close()
        for c in containers(voila):
            voila.run("stop", c["id"], check=False)
            voila.run("rm", c["id"], check=False)


def test_run_image_user(voila: Voila, tmp_path: Path) -> None:
    if shutil.which("newuidmap") is None:
        pytest.skip("newuidmap not installed")
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    subuid = Path("/etc/subuid")
    if not subuid.exists() or (
        user and user not in subuid.read_text() and str(os.getuid()) not in subuid.read_text()
    ):
        pytest.skip("no subuid range for this user")
    ctx = tmp_path / "usertest"
    ctx.mkdir()
    (ctx / "Dockerfile").write_text(f'FROM {BASE}\nUSER nobody\nCMD ["id"]\n')
    voila.run("import", BASE)
    voila.run("build", "-t", "usertest:1", str(ctx))
    res = voila.run("run", "--rm", "usertest:1")
    assert "uid=65534(nobody)" in res.out, res.out


def test_build_copy_chown_dot_keeps_workdir(voila: Voila, tmp_path: Path) -> None:
    ctx = tmp_path / "copybug"
    ctx.mkdir()
    (ctx / "app.py").write_text("hello\n")
    (ctx / "Dockerfile").write_text(
        f"FROM {BASE}\nWORKDIR /srv\nCOPY --chown=1:1 app.py .\nCMD [\"cat\", \"/srv/app.py\"]\n"
    )
    voila.run("import", BASE)
    voila.run("build", "-t", "copybug:1", str(ctx))
    res = voila.run("run", "--rm", "copybug:1", "--", "sh", "-c", "ls -ld /srv; cat /srv/app.py")
    assert "hello" in res.out
    assert "not a directory" not in res.err.lower()


def test_push_pull_org_slash_ref(machine: Machine, registry_server: Registry, tmp_path: Path) -> None:
    a, b = machine("a"), machine("b")
    a.run("import", BASE)
    a.run("build", "-t", "testorg/hello:1", str(write_hello_context(tmp_path / "ctx")))
    a.run("push", "testorg/hello:1")
    assert b.run("run", "--rm", "testorg/hello:1").out == "hello world\n"
    assert len(registry_server.state.images) >= 1


def _can_connect(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), 0.5):
            return True
    except OSError:
        return False
