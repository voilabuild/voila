import time
from pathlib import Path

from conftest import Machine, Registry, Voila

BASE = "alpine:3.20"


def write_hello_context(ctx: Path) -> Path:
    ctx.mkdir()
    (ctx / "hello.txt").write_text("hello world\n")
    (ctx / "Dockerfile").write_text(
        f'FROM {BASE}\nCOPY hello.txt /hello.txt\nCMD ["cat", "/hello.txt"]\n'
    )
    return ctx


def test_rmi_missing_image_exits_nonzero(voila: Voila) -> None:
    res = voila.run("rmi", "nope:1", check=False)
    assert res.rc == 1, res.err
    assert "no such image nope:1" in res.err
    assert "Removed" not in res.out and "Removed" not in res.err


def test_run_hello(voila: Voila) -> None:
    voila.run("import", BASE)
    res = voila.run("run", "--rm", BASE, "--", "echo", "hello world")
    assert res.out == "hello world\n"

    res = voila.run("run", "--rm", BASE, "--", "sh", "-c", "exit 7", check=False)
    assert res.rc == 7


def test_version_and_help(voila: Voila) -> None:
    ver = voila.run("--version")
    assert ver.rc == 0
    assert ver.err.startswith("voila ") or ver.out.startswith("voila ")
    help_ = voila.run("run", "--help")
    assert help_.rc == 0
    text = help_.err + help_.out
    assert "-p" in text and "--name" in text
    assert "SqlitePrepare" not in text


def test_missing_image_is_human(voila: Voila) -> None:
    res = voila.run("run", "--rm", "nope:1", "--", "true", check=False)
    assert res.rc != 0
    err = res.err + res.out
    assert "SqlitePrepare" not in err
    assert "NoImageMatch" not in err
    assert "not found" in err.lower() or "import" in err.lower()


def test_unknown_command_exits_127(voila: Voila) -> None:
    voila.run("import", BASE)
    res = voila.run("run", "--rm", BASE, "--", "nosuchcmd", check=False)
    assert res.rc == 127, res.err
    assert "SqlitePrepare" not in res.err
    assert "not found" in res.err.lower() or "nosuchcmd" in res.err.lower()


def test_build_hello(voila: Voila, tmp_path: Path) -> None:
    ctx = write_hello_context(tmp_path / "ctx")
    voila.run("import", BASE)
    voila.run("build", "-t", "hello:1", str(ctx))
    assert voila.run("run", "--rm", "hello:1").out == "hello world\n"

    rebuild = voila.run("build", "-t", "hello:1", str(ctx))
    steps = [line for line in rebuild.err.splitlines() if "COPY" in line]
    assert steps and all("CACHED" in line for line in steps), rebuild.err


def test_push_pull_hello(
    machine: Machine, registry_server: Registry, tmp_path: Path
) -> None:
    a, b = machine("a"), machine("b")
    a.run("import", BASE)
    a.run("build", "-t", "hello:1", str(write_hello_context(tmp_path / "ctx")))
    a.run("push", "hello:1")
    pushed = len(registry_server.state.chunk_puts)
    assert pushed > 0

    assert b.run("run", "--rm", "hello:1").out == "hello world\n"
    fetched = len(registry_server.state.chunk_gets)
    assert 0 < fetched < pushed, f"fetched {fetched} of {pushed} chunks"


def test_push_overlaps_chunk_puts(machine: Machine, registry_server: Registry, tmp_path: Path) -> None:
    ctx = tmp_path / "many"
    ctx.mkdir()
    lines = ["FROM scratch"]
    for i in range(24):
        (ctx / f"f{i}.txt").write_text(f"chunk-payload-{i}\n")
        lines.append(f"COPY f{i}.txt /f{i}.txt")
    (ctx / "Dockerfile").write_text("\n".join(lines) + "\n")
    a = machine("a")
    a.run("build", "-t", "many:1", str(ctx))
    registry_server.state.put_delay_ms = 50
    t0 = time.monotonic()
    a.run("push", "many:1")
    elapsed = time.monotonic() - t0
    n = len(registry_server.state.chunk_puts)
    assert n >= 24, n
    serial = n * 0.05
    assert elapsed < serial * 0.6, f"push took {elapsed:.2f}s for {n} chunks (serial {serial:.2f}s)"
    assert registry_server.state.max_inflight > 1, registry_server.state.max_inflight
