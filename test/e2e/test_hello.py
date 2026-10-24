from collections.abc import Callable
from pathlib import Path

from conftest import Registry, Voila

BASE = "alpine:3.20"


def write_hello_context(ctx: Path) -> Path:
    ctx.mkdir()
    (ctx / "hello.txt").write_text("hello world\n")
    (ctx / "Dockerfile").write_text(
        f'FROM {BASE}\nCOPY hello.txt /hello.txt\nCMD ["cat", "/hello.txt"]\n'
    )
    return ctx


def test_run_hello(voila: Voila) -> None:
    voila.run("import", BASE)
    res = voila.run("run", "--rm", BASE, "--", "echo", "hello world")
    assert res.out == "hello world\n"

    res = voila.run("run", "--rm", BASE, "--", "sh", "-c", "exit 7", check=False)
    assert res.rc == 7


def test_build_hello(voila: Voila, tmp_path: Path) -> None:
    ctx = write_hello_context(tmp_path / "ctx")
    voila.run("import", BASE)
    voila.run("build", "-t", "hello:1", str(ctx))
    assert voila.run("run", "--rm", "hello:1").out == "hello world\n"

    rebuild = voila.run("build", "-t", "hello:1", str(ctx))
    steps = [line for line in rebuild.err.splitlines() if "COPY" in line]
    assert steps and all("CACHED" in line for line in steps), rebuild.err


def test_push_pull_hello(
    machine: Callable[[str], Voila], registry_server: Registry, tmp_path: Path
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
