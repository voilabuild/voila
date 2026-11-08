import os
from pathlib import Path

from conftest import Machine, Registry, Voila

BASE = "alpine:3.20"


def build_and_push(machine: Machine, tmp_path: Path) -> None:
    ctx = tmp_path / "ctx"
    (ctx / "d" / "sub").mkdir(parents=True)
    (ctx / "big").mkdir()
    for name in "abcde":
        (ctx / "d" / name).write_bytes(f"file {name}\n".encode() * 100)
    (ctx / "d" / "sub" / "x").write_bytes(b"in a subdirectory\n" * 100)
    (ctx / "big" / "a").write_bytes(b"small file next to a big one\n" * 100)
    (ctx / "big" / "huge").write_bytes(os.urandom(9 << 20))
    (ctx / "Dockerfile").write_text(f"FROM {BASE}\nCOPY d /d\nCOPY big /big\n")
    a = machine("a")
    a.run("import", BASE)
    a.run("build", "-t", "dirs:1", str(ctx))
    a.run("push", "dirs:1")


def chunk_gets(machine: Voila, registry_server: Registry, script: str, *flags: str) -> int:
    registry_server.state.chunk_gets.clear()
    # The sleep keeps the FUSE server up until queued prefetches have landed.
    machine.run("run", "--rm", *flags, "dirs:1", "--", "sh", "-c", f"{script}sleep 1")
    return sum(registry_server.state.chunk_gets.values())


def test_prefetch_dirs_fetches_sibling_files_only(machine: Machine, registry_server: Registry, tmp_path: Path) -> None:
    """By default, reading /d/a also fetches /d/b../d/e, but not /d/sub/x, and
    nothing next to /big/a, whose directory holds more than 8 MiB. Each count is taken
    against a run that reads neither, so the base image's own directories cancel out."""
    build_and_push(machine, tmp_path)
    base = chunk_gets(machine("base"), registry_server, "")
    d = chunk_gets(machine("d"), registry_server, "cat /d/a >/dev/null; ")
    big = chunk_gets(machine("big"), registry_server, "cat /big/a >/dev/null; ")
    assert (d - base, big - base) == (5, 1), (base, d, big)


def test_no_prefetch_dirs_fetches_only_what_is_read(machine: Machine, registry_server: Registry, tmp_path: Path) -> None:
    build_and_push(machine, tmp_path)
    base = chunk_gets(machine("base"), registry_server, "", "--no-prefetch-dirs")
    d = chunk_gets(machine("d"), registry_server, "cat /d/a >/dev/null; ", "--no-prefetch-dirs")
    assert d - base == 1, (base, d)
