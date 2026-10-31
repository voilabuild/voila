"""Build the test registry (registry.py) into an image, serve it from voila, and push through it."""

import time
import urllib.request
from pathlib import Path

import pytest

from conftest import Machine, Voila, free_port
from test_hello import write_hello_context

E2E = Path(__file__).parent


def wait_http(url: str, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            with urllib.request.urlopen(url, timeout=1):
                return
        except OSError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.2)


def test_registry_image(machine: Machine, tmp_path: Path) -> None:
    host = machine("host")
    host.run("import", "python:3.13-alpine")
    host.run("import", "ghcr.io/astral-sh/uv:0.13.5")
    host.run("build", "-t", "e2e/registry:1", str(E2E))

    port = free_port()
    url = f"http://127.0.0.1:{port}"
    host.run("run", "-d", "--name", "registry", "-p", f"{port}:{port}", "-e", f"PORT={port}", "e2e/registry:1")
    try:
        try:
            wait_http(f"{url}/registry/v1/registry/config")
        except OSError:
            pytest.fail(f"registry container never answered:\n{host.run('logs', 'registry', check=False).out}")
        push_pull_through(machine("a", url), machine("b", url), tmp_path)
    finally:
        host.run("stop", "registry", check=False)
        host.run("rm", "registry", check=False)


def push_pull_through(a: Voila, b: Voila, tmp_path: Path) -> None:
    a.run("import", "alpine:3.20")
    a.run("build", "-t", "hello:1", str(write_hello_context(tmp_path / "ctx")))
    a.run("push", "hello:1")
    assert b.run("run", "--rm", "hello:1").out == "hello world\n"
